---
title: Backups
sidebar_label: Backups
slug: /configuration/backups
---

# Backups

Crumb's Postgres database is the sole index mapping every recorded `.mp4`
file to its camera and time. Lose that database with no backup, and the
footage still sitting on disk becomes effectively unplayable, nothing else
knows what any of those files are.

## Built into the API, on by default

The `api` service runs a nightly `pg_dump` on its own, no separate
container, no extra credentials, no setup required.

- **When:** daily at 03:15 local time by default (`DB_BACKUP_SCHEDULE`,
  timezone from `TZ`), plus an immediate catch-up dump on boot whenever the
  newest backup is missing or older than about 25 hours. A fresh install
  gets its first backup within seconds of the API starting.
- **What:** a gzipped, plain-SQL dump (`--no-owner --no-privileges`),
  written atomically, a temp file first, then renamed after an integrity
  check.
- **Where:** `DB_BACKUP_HOST_PATH` (default `./backups`), with
  daily/weekly/monthly rotation:

  ```text
  daily/crumb-YYYYMMDD-HHMMSS.sql.gz
  daily/crumb-latest.sql.gz     # symlink to the newest daily dump
  weekly/crumb-<ISOyear><week>.sql.gz
  monthly/crumb-YYYYMM.sql.gz   # only if DB_BACKUP_KEEP_MONTHS > 0
  ```

- **Rotation** keeps the newest N daily, weekly, and monthly dumps
  (configurable, see [Environment reference](/configuration/environment-reference)).
  It never deletes the newest dump, and it only ever touches files matching
  its own naming pattern, a manual dump you drop in the same directory is
  never at risk.
- **Failures are reported directly**: a failed run raises the
  `backup_failed` alert immediately through whatever notification channels
  you've configured, and a separate freshness watchdog catches the case
  where the job silently stopped running at all.

## The one thing to get right: permissions

The `api` container runs as uid 1001, so the host directory behind
`DB_BACKUP_HOST_PATH` needs to be writable by that uid:

```bash
sudo chown -R 1001:1001 "${DB_BACKUP_HOST_PATH:-./backups}"
```

`scripts/setup-env.sh` prepares the default `./backups` directory for you
when it can. If the directory isn't writable, the API logs a clear
warning, raises one `backup_failed` alert, and disables backups without
affecting anything else, a broken backup path never takes the API down.

## Verifying it's working

```bash
docker compose logs api | grep -i backup
ls -lh "${DB_BACKUP_HOST_PATH:-./backups}"/daily/
zcat "${DB_BACKUP_HOST_PATH:-./backups}"/last/crumb-latest.sql.gz | head -3
```

You should see a recent `.sql.gz`, a `database backup written` log line
(not a permissions warning), and output that looks like `pg_dump` SQL.

## Off-host copies

The built-in job protects you against losing the database itself, a bad
migration, an accidental `DROP TABLE`, disk corruption. It does not
protect you against losing the whole host: the dumps still live on the
same box as the footage. For a single-box home install, that's a fine,
accepted posture if you've made your peace with "if the box dies, I've
lost the video anyway." If you want a copy that survives losing the host
entirely, pick one:

**Point `DB_BACKUP_HOST_PATH` at a NAS or NFS mount.** No extra container,
no new configuration, dumps land off-host the moment `pg_dump` finishes.

**Or enable the optional `backup-offsite` service**, an rclone sidecar
gated behind the `offsite` Compose profile, so it's absent from a stock
install unless you opt in:

```bash
docker compose --profile offsite up -d
```

It syncs `DB_BACKUP_HOST_PATH` outward to whatever remote you configure in
`rclone.conf` (SFTP, S3, another NAS, and roughly seventy other backends),
read-only against the local directory, so it only ever pushes, never
deletes or restores.

## Restoring

The built-in job's dumps restore into an empty database, not one with the
existing schema still in it:

```bash
docker compose stop recorder api

docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d postgres -c \
  "DROP DATABASE \"${POSTGRES_DB}\"; CREATE DATABASE \"${POSTGRES_DB}\" OWNER \"${POSTGRES_USER}\";"

gunzip -c "${DB_BACKUP_HOST_PATH:-./backups}/daily/<dump-file>.sql.gz" \
  | docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"

docker compose up -d recorder api
```

Bringing `recorder`/`api` back up lets the recorder's startup
reconciliation re-index any segment files written after the restored
dump's timestamp. Run a restore drill on a spare host before you rely on
this in production, an untested backup isn't a backup.

## Turning it off

Set `DB_BACKUP_ENABLED=false` and `docker compose up -d api` if you'd
rather run your own backup mechanism against the same database.
