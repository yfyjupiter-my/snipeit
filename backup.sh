#!/bin/bash

# --- CONFIGURATION ---
BACKUP_DIR="./backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
CONTAINER_NAME="db"  # Matches 'db' service in your docker-compose.yml
ENV_FILE=".env"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR/$TIMESTAMP"

echo "Starting Snipe-IT backup for $TIMESTAMP..."

# 1. Export Environment Variables for DB access
source $ENV_FILE

# 2. Backup Database
echo "Exporting database..."
docker compose exec -t $CONTAINER_NAME mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" "$DB_DATABASE" > "$BACKUP_DIR/$TIMESTAMP/db_backup.sql"

# 3. Backup Storage Volume
echo "Compressing storage volume..."
# This finds the volume name automatically based on your directory name
VOLUME_NAME=$(docker volume ls -q | grep "_storage")
docker run --rm -v "$VOLUME_NAME":/volume -v "$(pwd)/$BACKUP_DIR/$TIMESTAMP":/backup alpine tar czf /backup/storage_backup.tar.gz -C /volume .

# 4. Copy Config Files
echo "Copying config files..."
cp .env docker-compose.yml "$BACKUP_DIR/$TIMESTAMP/"

# 5. Cleanup (Optional: Remove backups older than 30 days)
# find $BACKUP_DIR/* -type d -ctime +30 -exec rm -rf {} +

echo "Backup complete! Files are located in: $BACKUP_DIR/$TIMESTAMP"
