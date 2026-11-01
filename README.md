# FreshRSS LXC Updater (Edge / Git)

Automatisation des mises à jour pour FreshRSS hébergé dans un conteneur LXC Proxmox.

## Fonctionnalités
- Branche de développement `edge` suivie via Git.
- Sauvegarde préventive automatique de `data/` et `extensions/` avant toute mise à niveau.
- Préservation et correction stricte des permissions pour le serveur Apache (`www-data:www-data`).
- Exécution automatique planifiée chaque dimanche à 03h30 via un timer systemd.
- Rotation paramétrable des sauvegardes.

## Déploiement rapide
1. Cloner ou copier les fichiers dans un dossier temporaire du conteneur LXC.
2. Lancer l'installation :
   ```bash
   chmod +x install.sh
   ./install.sh