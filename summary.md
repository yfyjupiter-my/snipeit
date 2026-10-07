# Snipe-IT Restore — Summary (2026-10-07)

A plain-language walkthrough of how the Snipe-IT database and files were restored,
so you can do it yourself next time.

---

## 1. The big picture

Snipe-IT keeps its data in **two places**. A restore means refilling both:

| What | Where it lives | Backup file |
|------|----------------|-------------|
| **Database** (assets, users, settings…) | Docker volume `snipeit_db_data`, used by the `db` container (MariaDB) | `db_backup.sql` |
| **Files** (uploaded images, attachments, keys) | Docker volume `snipeit_storage`, used by the `app` container | `storage_backup.tar.gz` |

A **Docker volume** is a folder that Docker manages for you. It keeps its contents when a
container is deleted or recreated.

The backup used was `backups/20261007_093801/`. It holds the two files above, plus
`.env` and `docker-compose.yml`.

---

## 2. Check before you change anything

Always find out what is already there first. These commands only read; they change nothing.

```bash
cd ~/Documents/snipeit

docker compose ps -a      # which containers exist and whether they are running
docker volume ls          # which volumes exist (look for snipeit_db_data, snipeit_storage)
ls backups/               # which backups you have

# Is the .env the same one the backup was made with? (APP_KEY must match!)
cmp .env backups/20261007_093801/.env && echo "same"
```

What we found:
- The `db` container was running, but the database had **0 tables**, so it was empty.
- The `snipeit_storage` volume held only empty folders.
- `.env` was identical to the backup's `.env`, so the `APP_KEY` was correct.

> **Why `APP_KEY` matters:** Snipe-IT uses this key to encrypt some data in the
> database. If the key changes, that data can no longer be read. Never regenerate it
> during a restore.

---

## 3. Restore the database

### Step 3a — Load the passwords from `.env` into your shell

```bash
set -a; source .env; set +a
```

`source .env` reads the file. `set -a` turns each variable into an environment
variable, so you can type `$MYSQL_ROOT_PASSWORD` instead of the real password.

### Step 3b — Start only the database container

```bash
docker compose up -d db
docker compose exec db healthcheck.sh --connect --innodb_initialized && echo "db ready"
```

On its first start, MariaDB **creates the empty database and user automatically**
from `DB_DATABASE`, `DB_USERNAME` and `DB_PASSWORD` in `.env`. You don't need to
create them by hand.

### Step 3c — Import the backup

```bash
docker compose exec -T db mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$DB_DATABASE" \
  < backups/20261007_093801/db_backup.sql
```

What each part does:
- `docker compose exec db` runs a command inside the `db` container.
- `-T` turns off the interactive terminal, which is needed when you feed a file in with `<`.
- `mariadb -u root -p... snipeit` opens the MariaDB client on the `snipeit` database.
- `< db_backup.sql` sends the backup file in. It is a plain-text list of SQL commands
  (`CREATE TABLE ...`, `INSERT ...`) that rebuild every table and row.

### Step 3d — Check that it worked

```bash
docker compose exec db mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$DB_DATABASE" \
  -e "SELECT COUNT(*) FROM assets; SELECT COUNT(*) FROM users;"
```

Result: **50 tables, 51 assets, 32 users.** ✅

---

## 4. Restore the files (create the folders)

### Step 4a — Create the storage volume without starting the app

```bash
docker compose create app
```

`create` makes the container **and its volumes** but does not start the app. This
creates the empty `snipeit_storage` volume. Because the app is not running yet,
nothing can write into the volume before the restore.

### Step 4b — Find the volume's real name

```bash
VOLUME_NAME=$(docker compose config --format json \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['volumes']['storage']['name'])")
echo $VOLUME_NAME      # -> snipeit_storage
```

Compose adds the project folder name as a prefix: `snipeit` + `_storage`. This is why
the project folder must stay named `snipeit`.

### Step 4c — Unpack the backup into the volume

```bash
docker run --rm \
  -v "$VOLUME_NAME":/volume \
  -v "$PWD/backups/20261007_093801":/backup:ro \
  alpine sh -c "rm -rf /volume/* && tar xzf /backup/storage_backup.tar.gz -C /volume"
```

This starts a tiny throwaway Linux container (`alpine`) that does the following:
1. Mounts the storage volume at `/volume`.
2. Mounts the backup folder at `/backup`. `:ro` makes it read-only, so the backup can't be damaged.
3. Empties the volume with `rm -rf /volume/*`.
4. Unpacks the archive into it with `tar xzf`. **The folders (`data/uploads/assets`,
   `keys`, `ssl`, …) are recreated from the archive.** You don't create them by hand.
5. `--rm` deletes the helper container afterwards.

> ⚠️ `rm -rf /volume/*` deletes everything in the volume. Only run it on a **new,
> empty** volume. We checked first: it held no files.

Result: **8 files restored** into the `data`, `dumps`, `keys` and `ssl` folders. ✅

---

## 5. Start everything and check

```bash
docker compose up -d
docker compose logs -f app          # Ctrl-C when it settles
curl -I http://127.0.0.1:8000       # expect 200 or 302
```

Results:
- The log said **"Nothing to migrate"**. The database structure already matches this
  Snipe-IT version, so the app has nothing to upgrade.
- `curl` returned **302**, a redirect to the login page, and the login page itself
  returned **200**. ✅
- There were no errors in the Laravel log.

> A **500 error** here usually means a wrong `APP_KEY`, or a database that didn't import.

---

## 6. Cheat sheet

```bash
cd ~/Documents/snipeit
B=backups/<timestamp>                       # pick your backup folder
set -a; source .env; set +a                 # load passwords

# Database
docker compose up -d db
docker compose exec -T db mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$DB_DATABASE" < $B/db_backup.sql

# Files
docker compose create app
docker run --rm -v snipeit_storage:/volume -v "$PWD/$B":/backup:ro alpine \
  sh -c "rm -rf /volume/* && tar xzf /backup/storage_backup.tar.gz -C /volume"

# Go
docker compose up -d
```

## 7. Automatic daily backup (cron job)

A **cron job** is a command that Linux runs automatically on a schedule. We added one
that runs `backup.sh` every night at **2:00 AM** (server time zone: Asia/Kuala_Lumpur).

### How it was added

```bash
crontab -e          # opens your personal schedule in an editor
```

Then add this line:

```
0 2 * * * cd /home/ubuntu/Documents/snipeit && bash backup.sh >> /home/ubuntu/Documents/snipeit/backups/backup.log 2>&1
```

How to read it:
- `0 2 * * *` is the schedule: minute 0, hour 2, every day, every month, every weekday.
  The five fields are `minute hour day-of-month month day-of-week`.
- `cd /home/ubuntu/Documents/snipeit` comes first because `backup.sh` saves to
  `./backups`, a path relative to the folder it runs from.
- `>> .../backups/backup.log 2>&1` adds the script's messages, including errors, to a
  log file. Cron has no screen, so without this you could never see what happened.

> **Tip:** cron runs with almost no environment and no terminal. Before trusting a job,
> test it the same way:
> `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'cd ~/Documents/snipeit && bash backup.sh' </dev/null`

### Where backups are saved

Each run creates a new folder named by date and time:

```
~/Documents/snipeit/backups/
├── 20261007_103842/
│   ├── db_backup.sql          ← the database
│   ├── storage_backup.tar.gz  ← uploaded files
│   ├── .env                   ← settings + passwords (keep private!)
│   └── docker-compose.yml
└── backup.log                 ← messages from every cron run
```

### Useful commands

```bash
crontab -l                                   # show scheduled jobs
ls -lt ~/Documents/snipeit/backups/          # newest backups first
tail ~/Documents/snipeit/backups/backup.log  # did last night's run work?
```

### Things to know

- The backups are on the **same disk** as Snipe-IT. Copy them to another machine
  from time to time, because a backup on the box it protects isn't a backup.
- Old backups are **not** deleted automatically: the cleanup line in `backup.sh` is
  commented out. Each one is about 0.6 MB.
- The `backups/` folder is excluded from git because it contains passwords.

---

## 8. Still to do

- Log in and open an asset with a picture, to confirm the files work.
- Nginx and TLS, and DNS cutover: README steps 7–8. These are only needed if
  people should reach Snipe-IT at `https://assets.maplescraps.com`.
- Change `APP_URL` in `.env` when moving to `assets.maplescraps.com`, then run `docker compose up -d`.
