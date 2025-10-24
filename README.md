# kanoma-build-image

Ce projet a pour but de construire des images de machines virtuelles (VM) pour Google Cloud Platform (GCP) de manière automatisée, reproductible et validée, en utilisant un pipeline CI/CD avec GitHub Actions.

## Objectifs

- **Automatisation** : Construire des images sans intervention manuelle.
- **Standardisation** : S'assurer que toutes les images sont basées sur une configuration commune et validée.
- **Validation** : Tester chaque image après sa construction pour garantir sa conformité.
- **Sécurité** : Utiliser des méthodes d'authentification modernes et sécurisées (Workload Identity Federation).

---

## 1. Composants Principaux

Notre pipeline s'articule autour de plusieurs outils clés :

| Outil | Rôle |
| :--- | :--- |
| **Packer** | L'outil principal qui orchestre la création de l'image sur GCP. |
| **Ansible** | Le provisioner utilisé par Packer pour configurer la VM (installer Nginx, etc.). |
| **Goss** | Un outil rapide de validation de serveur basé sur du YAML pour tester l'image. |
| **GitHub Actions** | L'orchestrateur CI/CD qui exécute les différentes étapes du processus. |

---

## 2. Fonctionnement du Pipeline de Build (`.github/workflows/build.yml`)

Le workflow principal est conçu pour être à la fois autonome et réutilisable. Il se décompose en deux phases (jobs) : `build` et `validate`.

### Déclencheurs

Le workflow peut être lancé de deux manières :
1.  **Manuellement (`workflow_dispatch`)** : Via l'interface GitHub Actions, en choisissant le projet GCP, le type d'image (RHEL 8/9) et si la validation doit être lancée.
2.  **Par un autre workflow (`workflow_call`)** : Permet à un workflow de planification (`schedule.yml`) de déclencher des builds nocturnes, par exemple.

### Phase 1 : Construction de l'image (`build`)

Ce job est responsable de la création de l'image brute.

1.  **Authentification GCP** : Le workflow s'authentifie sur GCP de manière sécurisée sans utiliser de clé de service JSON. Il utilise **Workload Identity Federation**, où GitHub est approuvé comme fournisseur d'identité pour un Service Account GCP.
    
    **Détail du fonctionnement de Workload Identity Federation (WIF)** :
    Workload Identity Federation est un mécanisme de sécurité qui permet à des identités externes (comme GitHub Actions) d'assumer l'identité d'un Service Account GCP sans avoir à télécharger et gérer des clés de service statiques.
    -   **Émission du jeton OIDC** : Lors de l'exécution du workflow GitHub Actions, GitHub génère un jeton OpenID Connect (OIDC). Ce jeton est signé par GitHub et contient des informations vérifiables sur l'identité du workflow (par exemple, le dépôt, l'organisation, le nom du workflow).
    -   **Échange avec GCP** : Le workflow utilise ce jeton OIDC pour s'authentifier auprès d'un **Pool d'Identités de Charge de Travail (Workload Identity Pool)** configuré dans GCP.
    -   **Vérification et confiance** : GCP vérifie la signature du jeton OIDC et s'assure que l'émetteur (GitHub) est un fournisseur d'identité de confiance configuré dans le pool.
    -   **Attribution du rôle de Service Account** : Si la vérification est réussie, GCP permet au workflow d'assumer l'identité du Service Account spécifié (`sa-buildimage@${{ inputs.project_id }}.iam.gserviceaccount.com`).
    -   **Jeton d'accès temporaire** : En retour, GCP fournit un jeton d'accès OAuth 2.0 de courte durée. Ce jeton permet au workflow d'interagir avec les services GCP en utilisant les permissions du Service Account, sans jamais exposer de clés de longue durée.
    
    **Prérequis pour le Service Account GCP (`sa-buildimage`)** :
    Pour que le Service Account `sa-buildimage` puisse effectuer toutes les opérations nécessaires à la construction et à la validation des images (création de VM temporaires, création d'images, etc.), il doit disposer des rôles IAM (Identity and Access Management) suivants sur le projet GCP cible (`${{ inputs.project_id }}`) :
    -   `roles/compute.instanceAdmin` : Ce rôle permet de gérer les instances Compute Engine. Il est nécessaire pour :
        -   Créer, démarrer, arrêter et supprimer les VM temporaires utilisées par Packer pour le build.
        -   Créer, démarrer, arrêter et supprimer les VM de test utilisées pour la validation.
    -   `roles/iap.tunnelResourceAccessor` : Ce rôle permet d'utiliser IAP pour effectuer la connexion ssh via Packer
    -   `roles/serviceAccountUser`         : Ce rôle permet d'utiliser un autre service account (celui de la VM pour la connexion IAP)
    
    > **Note** : Ces rôles doivent être attribués spécifiquement au Service Account `sa-buildimage@${{ inputs.project_id }}.iam.gserviceaccount.com` dans le projet GCP où les images seront construites.
    
2.  **Initialisation de Packer** : La commande `packer init` télécharge les plugins nécessaires (`googlecompute`, `ansible`).
    > **Point clé** : On utilise un `PACKER_GITHUB_API_TOKEN: ${{ secrets.GITHUB_TOKEN }}` pour éviter les erreurs de "rate limiting" de l'API GitHub.

3.  **Lancement du build Packer** : La commande `packer build` est exécutée.
    - Packer démarre une VM temporaire sur GCP à partir d'une image source (ex: `rhel-9-base`).
    - Une fois la VM démarrée, Packer se connecte en SSH et lance le playbook **Ansible** (`play_host_rhel_build.yml`).
    - Ansible installe et configure Nginx, crée la page `index.html` et s'assure que le service est démarré.
    - Une fois le provisionning terminé, Packer crée une image (snapshot) de la VM configurée.
    - La VM temporaire est détruite.

4.  **Récupération du nom de l'image** : Le nom de l'image finale, généré par Packer, est extrait du fichier `manifest.json` et passé en output pour la phase suivante.

### Phase 2 : Validation de l'image (`validate`)

Ce job ne s'exécute que si l'option `validate` est activée. Il garantit que l'image construite est conforme à nos attentes.

1.  **Création d'une instance de test** : Une nouvelle VM est créée sur GCP, cette fois-ci en utilisant **l'image que nous venons de construire**.

2.  **Exécution des tests Goss** :
    - L'exécutable `goss` est téléchargé sur l'instance de test.
    - Le fichier de définition des tests (`tests/goss.yaml`) est copié sur l'instance.
    - `goss` est exécuté sur l'instance. Il valide l'état du serveur en se basant sur les règles définies dans le fichier YAML :
        - Le paquet `nginx` est-il installé ?
        - Le service `nginx` est-il démarré et activé ?
        - Le port `80` est-il en écoute ?
        - Le fichier `index.html` a-t-il le bon contenu et les bonnes permissions ?
    - Si un de ces tests échoue, le workflow échoue.

3.  **Nettoyage** : L'étape `Cleanup test instance` s'exécute **toujours** (`if: always()`), même si les tests ont échoué. Elle supprime la VM de test pour éviter de laisser des ressources orphelines et de générer des coûts inutiles.

---

## 3. Builds Planifiés (`.github/workflows/schedule.yml`)

Pour garantir que nos images de base sont toujours à jour (par exemple, avec les derniers patchs de sécurité inclus dans l'image source), un second workflow est en place.

- Il se déclenche sur un `schedule` (ex: tous les dimanches à 3h du matin).
- Il ne contient aucune logique de build. Son seul rôle est d'appeler le workflow `build.yml` (une fois pour RHEL 8, une fois pour RHEL 9).
- Il force l'activation de la validation (`validate: true`), car il est crucial que les builds automatisés soient testés.

Cette séparation des préoccupations rend le système plus modulaire et facile à maintenir.

---

## 4. Structure du Dépôt

```
├── .github/workflows/
│   ├── build.yml         # Workflow principal de build et validation
│   └── schedule.yml      # Workflow pour les builds planifiés (cron)
├── ansible/
│   └── play_host_rhel_build.yml # Playbook pour configurer Nginx
├── templates/
│   ├── rhel-8/           # Fichiers de configuration Packer pour RHEL 8
│   └── rhel-9/           # Fichiers de configuration Packer pour RHEL 9
└── tests/
    └── goss.yaml         # Fichier de définition des tests de validation
```
