#!/bin/bash
# Snipe-IT backup: DB dump + storage volume + config, into ./backups/<timestamp>/.
# Exits non-zero on any failure, so cron's log and exit status are trustworthy.
set -euo pipefail

cd "$(dirname "$0")"

# --- CONFIGURATION (override in .env) ---
BACKUP_DIR="./backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DB_SERVICE="db"  # Matches 'db' service in docker-compose.yml

set -a; source .env; set +a
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"  # delete local backups older than this
BACKUP_MIN_KEEP="${BACKUP_MIN_KEEP:-7}"               # ...but always keep the newest N
OFFSITE_DEST="${OFFSITE_DEST:-}"                      # rsync target, e.g. user@host:/srv/snipeit-backups

DEST="$BACKUP_DIR/$TIMESTAMP"
WORK="$DEST.partial"
mkdir -p "$WORK"
# A failed run leaves no half-written folder that looks like a good backup.
trap 'rm -rf "$WORK"; echo "Backup FAILED for $TIMESTAMP" >&2' ERR

echo "Starting Snipe-IT backup for $TIMESTAMP..."

# 1. Backup Database
# -T: no TTY, so output isn't mangled and it works under cron.
# The password comes from .env over stdin, not the container's env (stale until the db container is
# recreated after a rotation), so it never appears in host or container argv.
echo "Exporting database..."
printf '%s' "$MYSQL_ROOT_PASSWORD" | docker compose exec -T "$DB_SERVICE" sh -c \
  'MYSQL_PWD=$(cat) exec mariadb-dump --single-transaction -u root "$MYSQL_DATABASE"' \
  > "$WORK/db_backup.sql"
# mariadb-dump writes this footer only when it finishes successfully.
tail -n 1 "$WORK/db_backup.sql" | grep -q "^-- Dump completed" \
  || { echo "Database dump is incomplete" >&2; false; }

# 2. Backup Storage Volume
echo "Compressing storage volume..."
# This finds this project's storage volume specifically (docker compose prefixes it with the project/dir name)
VOLUME_NAME=$(docker compose config --format json | python3 -c "import json,sys; print(json.load(sys.stdin)['volumes']['storage']['name'])")
docker run --rm -v "$VOLUME_NAME":/volume:ro -v "$(pwd)/$WORK":/backup alpine \
  sh -c 'tar czf /backup/storage_backup.tar.gz -C /volume . && tar tzf /backup/storage_backup.tar.gz > /dev/null'

# 3. Copy Config Files
echo "Copying config files..."
cp .env docker-compose.yml "$WORK/"

mv "$WORK" "$DEST"
trap - ERR
echo "Backup complete: $DEST"

# 4. Retention: only touch completed timestamp folders, newest first, skip the newest N.
# Age comes from the folder name (when the backup was taken), not mtime, which copies reset.
echo "Pruning backups older than $BACKUP_RETENTION_DAYS days (keeping newest $BACKUP_MIN_KEEP)..."
CUTOFF=$(date -d "-$BACKUP_RETENTION_DAYS days" +"%Y%m%d_%H%M%S")
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{8}_[0-9]{6}' -printf '%f\n' \
  | sort -r | tail -n +"$((BACKUP_MIN_KEEP + 1))" \
  | while read -r old; do
      if [[ "$old" < "$CUTOFF" ]]; then
        echo "  removing $old"
        rm -rf "${BACKUP_DIR:?}/$old"
      fi
    done

# 5. Off-site copy. A backup on the box it protects isn't a backup.
if [ -n "$OFFSITE_DEST" ]; then
  echo "Copying to off-site: $OFFSITE_DEST"
  rsync -a "$DEST" "$OFFSITE_DEST/"
  echo "Off-site copy complete."
else
  echo "WARNING: OFFSITE_DEST not set in .env; this backup exists on this host only." >&2
fi
