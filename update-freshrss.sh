#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[-] Fichier de configuration introuvable : $CONFIG_FILE"
  exit 1
fi

INSTALL_DIR=$(jq -r '.install_dir' "$CONFIG_FILE")
WEB_USER=$(jq -r '.web_user' "$CONFIG_FILE")
WEB_GROUP=$(jq -r '.web_group' "$CONFIG_FILE")
BACKUP_DIR=$(jq -r '.backup_dir' "$CONFIG_FILE")
MAX_BACKUPS=$(jq -r '.max_backups' "$CONFIG_FILE")
GIT_REPO=$(jq -r '.git_repo // "https://github.com/FreshRSS/FreshRSS.git"' "$CONFIG_FILE")
BRANCH=$(jq -r '.branch // "edge"' "$CONFIG_FILE")
SERVICES=$(jq -r '.restart_services[]?' "$CONFIG_FILE" || true)

echo "[*] Exécution du script de mise à jour FreshRSS ($BRANCH)..."

if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "[-] Le dossier d'installation $INSTALL_DIR n'existe pas."
  exit 1
fi

cd "$INSTALL_DIR"
git config --global --add safe.directory "$INSTALL_DIR" || true

# 1. Initialisation Git si l'instance est issue d'une archive
if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
  echo "[*] Dépôt Git absent. Initialisation et association à la branche $BRANCH..."
  git init
  git remote add origin "$GIT_REPO"
  git fetch origin "$BRANCH" --depth 1
  git checkout -f -B "$BRANCH" "origin/$BRANCH"
fi

git remote set-url origin "$GIT_REPO"
git fetch origin "$BRANCH" --quiet

LOCAL_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "none")
REMOTE_COMMIT=$(git rev-parse "origin/$BRANCH")

echo "[*] Commit local  : ${LOCAL_COMMIT:0:7}"
echo "[*] Commit distant: ${REMOTE_COMMIT:0:7}"

if [[ "$LOCAL_COMMIT" == "$REMOTE_COMMIT" ]]; then
  echo "[+] FreshRSS ($BRANCH) est déjà sur le commit le plus récent."
  exit 0
fi

echo "[*] Nouveaux commits détectés. Démarrage de la mise à jour..."

# 2. Sauvegarde des données utilisateurs
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"
ARCHIVE_NAME="${BACKUP_DIR}/freshrss_backup_edge_${TIMESTAMP}.tar.gz"

echo "[*] Sauvegarde de data/ et extensions/ dans $ARCHIVE_NAME..."
tar -czf "$ARCHIVE_NAME" \
  -C "$INSTALL_DIR" \
  --exclude="data/cache/*" \
  data extensions || true

# 3. Synchronisation Git
echo "[*] Alignement sur origin/$BRANCH..."
git reset --hard "origin/$BRANCH"

# 4. Rétablissement des permissions
echo "[*] Configuration des droits d'accès ($WEB_USER:$WEB_GROUP)..."
chown -R "${WEB_USER}:${WEB_GROUP}" "$INSTALL_DIR"
find "$INSTALL_DIR" -type f -exec chmod 0644 {} +
find "$INSTALL_DIR" -type d -exec chmod 0755 {} +
chmod -R 0775 "${INSTALL_DIR}/data"
chmod +x "${INSTALL_DIR}/cli/"*.php 2>/dev/null || true

# 5. Migration et maintenance CLI
if command -v php &>/dev/null; then
  echo "[*] Exécution des routines CLI FreshRSS..."
  su -s /bin/bash "$WEB_USER" -c "php ${INSTALL_DIR}/cli/actualize-user.php --all" || true
fi

# 6. Rechargement des services
if [[ -n "$SERVICES" ]]; then
  while IFS= read -r svc; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      echo "[*] Rechargement du service $svc..."
      systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc"
    fi
  done <<< "$SERVICES"
fi

# 7. Rotation des sauvegardes
find "$BACKUP_DIR" -type f -name "freshrss_backup_edge_*.tar.gz" | sort -r | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f

echo "[+] FreshRSS ($BRANCH) mis à jour avec succès sur le commit ${REMOTE_COMMIT:0:7}."