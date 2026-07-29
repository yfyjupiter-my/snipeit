# Snipe-IT Deployment

Docker Compose deployment of [Snipe-IT](https://snipeitapp.com/) (asset management) behind Nginx, for `assets.maplescraps.com`.

## Stack

- `app`: `snipe/snipe-it` (see `docker-compose.yml` for pinned version)
- `db`: MariaDB, data in `db_data` volume
- Uploaded files in `storage` volume
- Nginx reverse proxy with TLS (Let's Encrypt) — config in `assets.maplescraps.com.nginx`

## Deploy

1. Copy `example.env` to `.env` and fill in real values (see Configure below).
2. `docker compose up -d`
3. Generate the app key and add it to `.env` as `APP_KEY`:
   ```bash
   docker compose run --rm app php artisan key:generate --show
   ```
   Then `docker compose up -d` again to pick it up.
4. Install the Nginx site:
   ```bash
   sudo cp assets.maplescraps.com.nginx /etc/nginx/sites-available/assets.maplescraps.com
   sudo ln -s /etc/nginx/sites-available/assets.maplescraps.com /etc/nginx/sites-enabled/
   sudo nginx -t && sudo systemctl reload nginx
   ```
   Requires a cert already issued for `maplescraps.com` (e.g. via certbot) at the paths referenced in the config.

## Configure (`.env`)

Key settings in `.env` (start from `example.env` as a template):

- `APP_URL`, `APP_KEY`, `APP_TIMEZONE`
- `APP_PORT` — local port Nginx proxies to (default `8000`)
- `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`
- `MAIL_*` — outgoing mail server for notifications
- `PRIVATE_FILESYSTEM_DISK` / `PUBLIC_FILESYSTEM_DISK` — file storage backend

After changing `.env`: `docker compose up -d` to recreate affected containers.

## Manage

```bash
docker compose up -d          # start / apply config changes
docker compose down           # stop
docker compose logs -f app    # tail app logs
docker compose pull && docker compose up -d   # upgrade to a new image tag
```

## Backup

`backup.sh` dumps the DB, archives the storage volume, and copies `.env` + `docker-compose.yml` into a timestamped folder under `./backups/`:

```bash
./backup.sh
```

To restore: recreate the stack, load `db_backup.sql` into the `db` container, and extract `storage_backup.tar.gz` into the `storage` volume.

Old backup snapshots (`snipeit_db_backup.sql`, `snipeit_storage_backup.tar.gz`) are gitignored and kept locally only.

## Migrate to a new server

Export/import method, using the same `db_backup.sql` + `storage_backup.tar.gz` artifacts `backup.sh` produces.

**On the old server:**
```bash
./backup.sh                      # writes ./backups/<timestamp>/
scp -r backups/<timestamp> newhost:/tmp/snipeit-migration
```

**On the new server:**
1. Clone this repo, copy `docker-compose.yml` and `.env` from the backup folder (keeps `APP_KEY`, DB credentials, etc. identical — don't regenerate `APP_KEY`, it decrypts existing DB data).
2. Update `APP_URL` in `.env` if the hostname changed.
3. Start just the DB so it initializes its volume, then load the dump:
   ```bash
   docker compose up -d db
   docker compose exec -T db mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$DB_DATABASE" < /tmp/snipeit-migration/db_backup.sql
   ```
4. Restore the storage volume before first app start:
   ```bash
   docker compose up -d app   # creates the storage volume
   docker compose stop app
   VOLUME_NAME=$(docker volume ls -q | grep "_storage")
   docker run --rm -v "$VOLUME_NAME":/volume -v /tmp/snipeit-migration:/backup alpine \
     sh -c "rm -rf /volume/* && tar xzf /backup/storage_backup.tar.gz -C /volume"
   ```
5. `docker compose up -d` and verify at the new `APP_URL`.

Point DNS for `assets.maplescraps.com` at the new host and reinstall the Nginx site + TLS cert (see Deploy above) once verified.
