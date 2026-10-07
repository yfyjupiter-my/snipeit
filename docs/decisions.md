# Decisions

Short records of why this deployment looks the way it does. Add a new entry when you make a
choice that someone would otherwise have to rediscover; don't edit old entries, supersede them.

Format: **Status** (Accepted / Proposed / Superseded by N) · **Context** · **Decision** · **Consequences**.

---

## 1. Pin exact image versions; upgrade deliberately

**Status:** Accepted (2026-10-07)

**Context.** `docker-compose.yml` pins `snipe/snipe-it:v8.8.0` and `mariadb:11.4.7`. A floating tag
(`latest`, `v6`) would let a `docker compose pull` apply database migrations nobody planned for,
and a Snipe-IT migration can't be rolled back without restoring a backup.

**Decision.** Keep exact tags. Change them only in a commit of their own, following this procedure:

1. Run `./backup.sh` and confirm it exits 0.
2. Read the Snipe-IT release notes for every version you're skipping. Move one major version at a
   time (v6 → v7 → v8), not straight to the newest.
3. Bump the tag, then `docker compose pull && docker compose up -d`, and check `docker compose logs -f app`
   to confirm migrations ran.
4. Rollback means restoring the backup from step 1 with the old tag, not reverting the tag alone.

**Consequences.** No surprise upgrades, but upgrades don't happen unless someone does them.
The v6 → v8 upgrade is recorded in entry 5.

---

## 2. TLS terminates in Nginx on the host, not in a container

**Status:** Accepted (2026-10-07)

**Context.** The app container serves plain HTTP. Certificates come from Let's Encrypt via certbot,
which integrates with a host-installed Nginx and renews through its systemd timer.

**Decision.** Run Nginx on the host as the reverse proxy (`assets.maplescraps.com.nginx`, now tracked
in git) and proxy to `127.0.0.1:${APP_PORT}`. The site config contains no secrets: the certificate
paths point to files outside the repo.

**Consequences.** Certificate renewal is standard certbot with nothing custom. The proxy is not part
of `docker compose up`, so a new server needs the manual steps in the README's migration section.

**Open issue.** Compose publishes the app as `"${APP_PORT:-8000}:80"`, which binds on **all
interfaces**. On a server with Nginx in front, that leaves a plain-HTTP side door on port 8000 unless a
firewall blocks it. Production should use `"127.0.0.1:${APP_PORT:-8000}:80"`. It hasn't been changed
yet because the current host has no Nginx and may depend on direct `:8000` access.

---

## 3. `APP_KEY` is permanent

**Status:** Accepted (2026-10-07)

**Context.** Snipe-IT encrypts some database fields with `APP_KEY`. Data encrypted under one key
can't be read with another. A restore only works with the `.env` from the same deployment.

**Decision.** Never regenerate `APP_KEY` on an existing install, including during a restore or a
migration. `backup.sh` copies `.env` into every backup for this reason.

**Consequences.** Every backup folder contains secrets, which is why `backups/` is gitignored
and any off-site destination must be treated as sensitive.

**Open issue.** `.env` was committed in `b3b9e3a`/`8315188` and later removed. That removal doesn't
clean up history: the live `APP_KEY`, `DB_PASSWORD` and `MYSQL_ROOT_PASSWORD` can still be read from the
`origin` remote. The database passwords are straightforward to rotate. Rotating `APP_KEY` requires
re-encrypting the encrypted fields, so it needs its own plan. Rewriting history also needs every
clone to re-sync. Both are still to be decided.

---

## 4. Backups: logical dump + volume tarball, verified, pruned, copied off-site

**Status:** Accepted (2026-10-07). The off-site destination is still to be chosen.

**Context.** The state lives in two volumes, `db_data` and `storage`. The original script didn't stop
on errors, so a failed dump could still report "Backup complete!". It kept backups forever, on the
same disk as the data.

**Decision.** `backup.sh`, run nightly by cron at 02:00:

- Takes a `mariadb-dump --single-transaction` (a consistent snapshot, no downtime) and checks for the
  `-- Dump completed` footer. Tars the `storage` volume read-only and test-reads the archive.
- Writes into `<timestamp>.partial` and renames only on success. Exits non-zero on any failure.
- Deletes backups older than `BACKUP_RETENTION_DAYS` (30), judged by the folder name, but always
  keeps the newest `BACKUP_MIN_KEEP` (7). Without that floor, a month of failed runs would delete
  every good backup.
- Rsyncs the new folder to `OFFSITE_DEST` when it's set, and warns when it isn't.

A logical dump was chosen over copying the `db_data` volume because it restores across MariaDB
versions and doesn't need the database stopped.

**Consequences.** Restores follow `summary.md`. The script doesn't manage retention on the
off-site side, and no alert fires on failure: check `backups/backup.log`. Until `OFFSITE_DEST` is
set, losing the disk means losing both the data and its backups.

---

## 5. Upgrade Snipe-IT v6.3.4 → v8.8.0 in one step

**Status:** Done (2026-10-07)

**Context.** v6.3.4 was two major versions behind. v8.8.0 (2026-09-30) alone fixes 59 reported
security issues. The v7 and v8 release notes only call out PHP version requirements, which the
Docker image covers, and a CSS fix for reverse proxies, which doesn't apply here because `APP_URL`
points straight at `http://192.168.100.64:8000`.

**Decision.** The jump went straight from v6.3.4 to v8.8.0, against step 2 of entry 1, which says
to stop at v7 first. It wasn't a deliberate choice to skip the procedure. The image runs
`php artisan migrate --force` on startup, so the schema migrated as soon as the container started.

- Backup taken first: `backups/20261007_105504`.
- Migrations: 371 → 488 rows in `migrations`, no errors in the app log, `migrate:status` shows
  none pending.
- Row counts unchanged before and after: assets 51, users 32, licenses 6, accessories 2,
  action_logs 331.
- `/login` returns 200 and the stylesheet loads.

**Consequences.** Going back to v6.3.4 means restoring `backups/20261007_105504` with the old
tag; changing the tag alone won't work. Future upgrades follow entry 1 again, one major version
at a time.
