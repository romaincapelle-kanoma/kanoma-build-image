import os

def test_nginx_package_is_installed(host):
    """
    Vérification 1: Le paquet Nginx est installé.
    """
    nginx = host.package("nginx")
    assert nginx.is_installed

def test_nginx_service_is_running_and_enabled(host):
    """
    Vérification 2: Le service Nginx est actif et activé au démarrage.
    """
    nginx_service = host.service("nginx")
    assert nginx_service.is_running
    assert nginx_service.is_enabled

def test_nginx_is_listening_on_port_80(host):
    """
    Vérification 3: Nginx écoute sur le port 80.
    """
    # Vérifie les sockets en écoute sur toutes les interfaces IPv4 et IPv6
    assert host.socket("tcp://0.0.0.0:80").is_listening
    assert host.socket("tcp://:::80").is_listening

def test_homepage_content_and_permissions(host):
    """
    Vérification 4: Le contenu et les permissions de la page d'accueil sont corrects.
    """
    index_file = host.file("/usr/share/nginx/html/index.html")
    assert index_file.exists
    assert index_file.user == "nginx"
    assert index_file.group == "nginx"
    assert index_file.mode == 0o755
    assert index_file.contains("<h1>Bienvenue sur mon application</h1>")
