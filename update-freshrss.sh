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
NTFY_TOPIC=$(jq -r '.ntfy_topic // empty' "$CONFIG_FILE")
NTFY_TOKEN=$(jq -r '.ntfy_token // empty' "$CONFIG_FILE")

# Fonction de notification via Ntfy
notify() {
  local title="$1"
  local message="$2"
  local tags="${3:-information_source}"
  if [[ -n "$NTFY_TOPIC" ]]; then
    local auth_header=()
    if [[ -n "$NTFY_TOKEN" ]]; then
      auth_header=(-H "Authorization: Bearer $NTFY_TOKEN")
    fi
    curl -s -o /dev/null \
      "${auth_header[@]}" \
      -H "Title: $title" \
      -H "Tags: $tags" \
      -d "$message" \
      "$NTFY_TOPIC" || true
  fi
}

echo "[*] Exécution du script de mise à jour FreshRSS ($BRANCH)..."

if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "[-] Le dossier d'installation $INSTALL_DIR n'existe pas."
  notify "FreshRSS : Erreur critique" "Le dossier d'installation $INSTALL_DIR n'existe pas." "x,warning"
  exit 1
fi

# 0. Contrôle de l'espace disque (Minimum 1024 Mo / 1 Go)
FREE_KB=$(df -k "$INSTALL_DIR" | awk 'NR==2 {print $4}')
if [[ "$FREE_KB" -lt 1048576 ]]; then
  echo "[-] Espace disque insuffisant (< 1 Go libre). Annulation de la mise à jour."
  notify "FreshRSS : Espace disque insuffisant" "Il reste moins de 1 Go d'espace libre sur le conteneur. Mise à jour annulée pour éviter une corruption." "x,floppy_disk"
  exit 1
fi

# 1. Contrôle d'intégrité des bases SQLite avant toute opération
echo "[*] Vérification de l'intégrité des bases SQLite..."
for db in "$INSTALL_DIR"/data/users/*/db.sqlite; do
  if [[ -f "$db" ]]; then
    INTEGRITY=$(sqlite3 "$db" "PRAGMA quick_check;" 2>/dev/null || echo "error")
    if [[ "$INTEGRITY" != "ok" ]]; then
      echo "[-] Base de données corrompue détectée : $db"
      notify "FreshRSS : Base corrompue" "Erreur d'intégrité détectée sur $db. La mise à jour est suspendue." "x,warning"
      exit 1
    fi
  fi
done

cd "$INSTALL_DIR"
git config --global --add safe.directory "$INSTALL_DIR" || true

# 2. Initialisation Git si l'instance est issue d'une archive
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

# 3. Sauvegarde des données utilisateurs
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"
ARCHIVE_NAME="${BACKUP_DIR}/freshrss_backup_edge_${TIMESTAMP}.tar.gz"

echo "[*] Sauvegarde de data/ et extensions/ dans $ARCHIVE_NAME..."
if ! tar -czf "$ARCHIVE_NAME" -C "$INSTALL_DIR" --exclude="data/cache/*" data extensions; then
  echo "[-] Échec de la création de la sauvegarde. Annulation."
  notify "FreshRSS : Échec de la sauvegarde" "Impossible de créer l'archive de sauvegarde dans $BACKUP_DIR. La mise à jour a été interrompue." "x,warning"
  exit 1
fi

# 4. Synchronisation Git
echo "[*] Alignement sur origin/$BRANCH..."
git reset --hard "origin/$BRANCH"

# 5. Rétablissement des permissions et création des dossiers requis
echo "[*] Configuration des droits d'accès ($WEB_USER:$WEB_GROUP)..."
mkdir -p "$INSTALL_DIR/data/"{cache,users,favicons,tokens}
chown -R "${WEB_USER}:${WEB_GROUP}" "$INSTALL_DIR"
find "$INSTALL_DIR" -type f -exec chmod 0644 {} +
find "$INSTALL_DIR" -type d -exec chmod 0755 {} +
find "$INSTALL_DIR/data" -type d -exec chmod 0775 {} +
find "$INSTALL_DIR/data" -type f -exec chmod 0664 {} +
chmod +x "${INSTALL_DIR}/cli/"*.php 2>/dev/null || true

# 6. Rechargement des services pour appliquer le nouveau code
if [[ -n "$SERVICES" ]]; then
  while IFS= read -r svc; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      echo "[*] Rechargement du service $svc..."
      systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc"
    fi
  done <<< "$SERVICES"
fi

# 7. Test de santé post-déploiement avec Rollback automatique
echo "[*] Vérification de la santé de l'application (Health Check)..."
sleep 2
HTTP_CODE=$(curl -kfsSL -o /dev/null -w "%{http_code}" http://127.0.0.1/p/ || echo "000")

if [[ "$HTTP_CODE" =~ ^(5..|000)$ ]]; then
  echo "[-] FreshRSS renvoie une erreur HTTP $HTTP_CODE après déploiement."
  echo "[-] DÉCLENCHEMENT DU ROLLBACK vers le commit $LOCAL_COMMIT..."
  
  # Restauration du code précédent
  git reset --hard "$LOCAL_COMMIT"
  
  # Restauration de la sauvegarde data/ extensions/
  tar -xzf "$ARCHIVE_NAME" -C "$INSTALL_DIR"
  
  # Rétablissement des permissions
  chown -R "${WEB_USER}:${WEB_GROUP}" "$INSTALL_DIR"
  
  # Redémarrage du serveur web
  if [[ -n "$SERVICES" ]]; then
    while IFS= read -r svc; do
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl restart "$svc"
      fi
    done <<< "$SERVICES"
  fi
  
  notify "FreshRSS : Échec et Rollback" "La mise à jour a échoué (Erreur HTTP $HTTP_CODE). Le système a automatiquement restauré le commit précédent (${LOCAL_COMMIT:0:7})." "x,rotating_light"
  exit 1
fi

echo "[+] Health Check réussi (Code: $HTTP_CODE)."

# 8. Migration et maintenance CLI (uniquement si le code est sain)
if command -v php &>/dev/null; then
  echo "[*] Vérification de l'état des actualisations..."
  
  MAX_WAIT=15
  WAIT_COUNT=0
  
  while pgrep -f "actualize_script.php" >/dev/null 2>&1 || find "${INSTALL_DIR}/data" -maxdepth 2 -name "*actualize*.lock" 2>/dev/null | grep -q .; do
    if [[ $WAIT_COUNT -ge $MAX_WAIT ]]; then
      echo "[!] Une actualisation est déjà en cours (ou verrouillée). Étape ignorée."
      break
    fi
    echo "[*] Actualisation en cours, attente... (${WAIT_COUNT}/${MAX_WAIT}s)"
    sleep 3
    WAIT_COUNT=$((WAIT_COUNT + 3))
  done

  if ! pgrep -f "actualize_script.php" >/dev/null 2>&1 && ! find "${INSTALL_DIR}/data" -maxdepth 2 -name "*actualize*.lock" 2>/dev/null | grep -q .; then
    echo "[*] Lancement de l'actualisation des flux..."
    su -s /bin/bash "$WEB_USER" -c "php ${INSTALL_DIR}/app/actualize_script.php" || true
  fi
fi

# 9. Maintenance planifiée : Purge des caches et rotation
echo "[*] Purge des anciens fichiers de cache (plus de 14 jours)..."
find "$INSTALL_DIR/data/cache" -type f -mtime +14 -delete 2>/dev/null || true

if [[ -f /tmp/FreshRSS.log ]] && [[ $(stat -c%s /tmp/FreshRSS.log 2>/dev/null || echo 0) -gt 52428800 ]]; then
  echo "[*] Troncature du fichier journal de FreshRSS..."
  tail -n 1000 /tmp/FreshRSS.log > /tmp/FreshRSS.log.tmp && mv /tmp/FreshRSS.log.tmp /tmp/FreshRSS.log
fi

echo "[*] Rotation des archives de sauvegarde..."
find "$BACKUP_DIR" -type f -name "freshrss_backup_edge_*.tar.gz" | sort -r | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f

echo "[+] FreshRSS ($BRANCH) mis à jour avec succès sur le commit ${REMOTE_COMMIT:0:7}."
notify "FreshRSS : Mise à jour réussie" "L'instance a été mise à jour avec succès sur la branche $BRANCH (commit ${REMOTE_COMMIT:0:7})." "white_check_mark,tada"
