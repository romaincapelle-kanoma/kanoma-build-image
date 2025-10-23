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
| **Testinfra** | Un framework de test en Python pour valider l'état de la VM après sa création. |
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

2.  **Configuration de l'environnement de test** : Un environnement Python est mis en place.

3.  **Exécution des tests Testinfra** :
    - Les dépendances (`pytest`, `testinfra`) sont installées.
    - `pytest` est lancé. Il se connecte à l'instance de test via le connecteur `gce` (qui utilise les credentials `gcloud`).
    - Les tests définis dans `tests/testinfra/test_image.py` sont exécutés :
        - Le paquet `nginx` est-il installé ?
        - Le service `nginx` est-il démarré et activé ?
        - Le port `80` est-il en écoute ?
        - Le fichier `index.html` a-t-il le bon contenu et les bonnes permissions ?
    - Si un de ces tests échoue, le workflow échoue.

4.  **Nettoyage** : L'étape `Cleanup test instance` s'exécute **toujours** (`if: always()`), même si les tests ont échoué. Elle supprime la VM de test pour éviter de laisser des ressources orphelines et de générer des coûts inutiles.

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
└── tests/testinfra/
    ├── requirements.txt  # Dépendances Python pour les tests
    └── test_image.py     # Scénarios de test pour valider l'image
```
