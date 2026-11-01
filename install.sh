#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/opt/freshrss-lxc-updater"

if [[ $EUID -ne 0 ]]; then
  echo "[-] Ce script doit être exécuté en tant que root."
  exit 1
fi

echo "[*] Installation des paquets requis..."
apt-get update -qq
apt-get install -y -qq jq curl git tar rsync

echo "[*] Déploiement des fichiers dans $TARGET_DIR..."
mkdir -p "$TARGET_DIR"
mkdir -p "/var/backups/freshrss"

cp -r ./* "$TARGET_DIR/" 2>/dev/null || true
chmod +x "$TARGET_DIR/update-freshrss.sh"
chmod +x "$TARGET_DIR/install.sh"

if [[ ! -f "$TARGET_DIR/config.json" ]]; then
  echo "[*] Création de config.json à partir de config.json.example..."
  cp "$TARGET_DIR/config.json.example" "$TARGET_DIR/config.json"
fi

echo "[*] Mise en place des unités systemd..."
cp "$TARGET_DIR/systemd/freshrss-update.service" /etc/systemd/system/
cp "$TARGET_DIR/systemd/freshrss-update.timer" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now freshrss-update.timer

echo "[+] Installation terminée avec succès."
echo "[+] Vous pouvez exécuter une mise à jour test avec : systemctl start freshrss-update.service"