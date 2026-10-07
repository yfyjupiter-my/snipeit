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

It exits non-zero on any failure, verifies the dump finished (`-- Dump completed` footer) and the
tarball is readable, and never leaves a half-written folder behind. Settings in `.env`:

- `BACKUP_RETENTION_DAYS` (default `30`) / `BACKUP_MIN_KEEP` (default `7`): backups older than the
  retention are deleted, but the newest N are always kept, so a stretch of failed runs can't prune
  everything.
- `OFFSITE_DEST`: rsync target (e.g. `user@backup-host:/srv/snipeit-backups`) for an off-site copy.
  Needs passwordless SSH from this host. If empty, the script warns that the backup is local only.
  Retention on the off-site side is not managed by this script.

To restore: recreate the stack, load `db_backup.sql` into the `db` container, and extract `storage_backup.tar.gz` into the `storage` volume.

Old backup snapshots (`snipeit_db_backup.sql`, `snipeit_storage_backup.tar.gz`) are gitignored and kept locally only.

## Migrate to a new server (Ubuntu 26.04)

Export/import of the `db_backup.sql` + `storage_backup.tar.gz` artifacts `backup.sh` produces.
Nothing in the DB or storage volume is host-specific, so this is a copy, not a rebuild.

Plan for ~15 min of downtime at step 5. Keep the old server running and untouched
until step 8 passes — that is the rollback.

### 1. New server prerequisites

```bash
sudo apt update && sudo apt install -y ca-certificates curl nginx
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $CODENAME stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker $USER   # log out and back in for this to take effect
```

If `apt update` 404s on the Docker repo, 26.04's codename isn't published there yet.
Either swap `$CODENAME` for the previous LTS (`noble`) in `docker.list`, or use Ubuntu's
own packages instead: `sudo apt install -y docker.io docker-compose-v2`.

Verify before continuing:
```bash
docker run --rm hello-world && docker compose version
```

### 2. Take a fresh backup on the old server

```bash
cd ~/Documents/snipeit
bash backup.sh
scp -r backups/<timestamp> newhost:/tmp/snipeit-migration
```

`<timestamp>` is printed by the script. The folder holds `db_backup.sql`,
`storage_backup.tar.gz`, `.env` and `docker-compose.yml`.

`.env` and the dump contain credentials — `scp` directly between hosts as above,
don't stage them anywhere shared, and delete `/tmp/snipeit-migration` at step 9.

### 3. Lay out the project on the new server

```bash
mkdir -p ~/Documents && cd ~/Documents
git clone git@github.com:yfyjupiter-my/snipeit.git
cd snipeit
cp /tmp/snipeit-migration/.env /tmp/snipeit-migration/docker-compose.yml .
chmod 600 .env
```

Copy `.env` from the backup rather than rebuilding it from `example.env`. **Do not
regenerate `APP_KEY`** — it decrypts data already in the DB, and a new key makes that
data unreadable. Keep the directory name `snipeit`: Compose derives volume names
(`snipeit_db_data`, `snipeit_storage`) from it.

Only edit `APP_URL` if the hostname is changing. Same hostname → change nothing.

### 4. Restore the database

```bash
set -a; source .env; set +a      # exports MYSQL_ROOT_PASSWORD / DB_DATABASE for the shell
docker compose up -d db
docker compose exec db healthcheck.sh --connect --innodb_initialized && echo "db ready"
docker compose exec -T db mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$DB_DATABASE" \
  < /tmp/snipeit-migration/db_backup.sql
```

Sanity check — asset count should match the old server:
```bash
docker compose exec db mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$DB_DATABASE" \
  -e "SELECT COUNT(*) FROM assets;"
```

### 5. Restore the storage volume

Create the volume without starting the app, so nothing writes to it before the restore:

```bash
docker compose create app
VOLUME_NAME=$(docker compose config --format json \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['volumes']['storage']['name'])")
docker run --rm -v "$VOLUME_NAME":/volume -v /tmp/snipeit-migration:/backup alpine \
  sh -c "rm -rf /volume/* && tar xzf /backup/storage_backup.tar.gz -C /volume"
```

`rm -rf /volume/*` is destructive — it is correct only on a volume you just created.
Never run this step against a server already holding real uploads.

### 6. Start the stack

```bash
docker compose up -d
docker compose logs -f app       # watch until it settles, then Ctrl-C
curl -I http://127.0.0.1:${APP_PORT:-8000}
```

Expect a `200` or a `302` to the login page. A `500` here is almost always a wrong
`APP_KEY` or a DB the dump didn't load into — recheck steps 3 and 4.

### 7. Nginx and TLS

Issue the cert first (needs DNS pointing here, or use a DNS-01 challenge to avoid
downtime), then install the site:

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot certonly --nginx -d assets.maplescraps.com
sudo cp assets.maplescraps.com.nginx /etc/nginx/sites-available/assets.maplescraps.com
sudo ln -s /etc/nginx/sites-available/assets.maplescraps.com /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

The shipped config points at `/etc/letsencrypt/live/maplescraps.com/`. If certbot
writes to `/etc/letsencrypt/live/assets.maplescraps.com/` instead, update the two
`ssl_certificate*` paths to match. Check the firewall allows 80/443
(`sudo ufw allow 'Nginx Full'` if ufw is active).

### 8. Cut over

1. Lower the DNS TTL for `assets.maplescraps.com` a day ahead if you can.
2. Before flipping DNS, test the new host directly:
   `curl -k --resolve assets.maplescraps.com:443:<new-ip> https://assets.maplescraps.com/`
3. Log in, check assets, users, and that an uploaded image/attachment loads
   (that last one proves the storage volume restore worked).
4. Point DNS at the new IP.
5. Stop the old stack once traffic has moved and a day has passed: `docker compose down`
   on the old host. Keep its volumes until you are confident.

Any data entered on the old server after step 2 is lost — stop using it from then on,
or redo steps 2/4/5 at cutover.

### 9. Finish up

```bash
rm -rf /tmp/snipeit-migration        # contains .env and the DB dump
sudo certbot renew --dry-run         # confirm auto-renewal works on the new host
bash backup.sh                       # first backup on the new host
crontab -e                           # e.g. 0 2 * * * cd ~/Documents/snipeit && bash backup.sh
```

Docker's `restart: unless-stopped` brings the stack back after reboot; no systemd unit
needed. Push backups off the machine — a backup on the box it protects isn't a backup.
