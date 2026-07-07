# Postgres backups, built into the api (default ON)

Crumb's Postgres `segments` table is the **sole index** mapping recorded
`.mp4` files to camera/time/keyframe data (see
`docs/OPS-BACKUP-RECOVERY.md`). Lose that database with no backup and the
video files still on disk are effectively unplayable, no client queries the
filesystem directly.

Crumb originally shipped a backup *script* (`scripts/backup-db.sh` +
`scripts/restore-db.sh`, see `docs/OPS-BACKUP-RECOVERY.md`) that nothing ran
automatically, then a third-party `db-backup` sidecar container
(`prodrigestivill/postgres-backup-local`). Both gaps are now closed in one
place: **the api service itself runs a nightly `pg_dump` with tiered
rotation**, zero setup, no extra image, and a failed dump reports straight
into the `backup_failed` system alert instead of only being inferred from
staleness.

## How it runs

- **Where:** implemented in the api (`services/api/src/db_backup.rs`), spawned
  as a background task at startup. It dumps over the same `DATABASE_URL` the
  api already uses, no new credentials, no extra container, one less image.
- **When:** daily at **03:15 local time** by default (`DB_BACKUP_SCHEDULE`,
  a wall-clock `HH:MM`; timezone from `TZ`, default `America/Los_Angeles`).
  Plus a **catch-up dump on boot** whenever the newest dump is missing or
  older than ~25 h, a fresh install gets its first backup within seconds of
  the api starting, and a host that was powered off at 03:15 self-heals on
  next boot.
- **What:** `pg_dump -Z1 --no-owner --no-privileges` (gzipped plain SQL; no
  owner/privilege statements, so dumps restore cleanly onto a
  differently-named role), written **atomically** (`.partial` temp file,
  integrity-checked, then renamed).
- **Where on disk** (`DB_BACKUP_HOST_PATH`, default `./backups`, bind-mounted
  read-write at `/backups` in the api container), same layout the old
  sidecar used, so existing backups and tooling keep working:

  ```text
  daily/crumb-YYYYMMDD-HHMMSS.sql.gz   # one per run
  daily/crumb-latest.sql.gz            # symlink -> newest daily dump
  weekly/crumb-<ISOyear><week>.sql.gz  # refreshed each run (hard link)
  monthly/crumb-YYYYMM.sql.gz          # only if DB_BACKUP_KEEP_MONTHS > 0
  last/crumb-latest.sql.gz             # symlink -> newest daily dump
  ```

- **Rotation:** keeps the newest `DB_BACKUP_KEEP_DAYS` daily,
  `DB_BACKUP_KEEP_WEEKS` weekly (ISO week), and `DB_BACKUP_KEEP_MONTHS`
  monthly dumps. Two hard guarantees: rotation **never deletes the newest
  dump**, and it **only touches files matching its own naming pattern**, a
  manual dump you drop in the same directory (including
  `scripts/backup-db.sh` output) is never deleted.
- **Failure reporting:** a failed run emits a `backup_failed` system event
  immediately (routed through the admin Notifications channels). The
  freshness watchdog in the api (fires when the newest dump is > ~25 h old)
  stays on as a backstop, it also catches "the job never ran at all".

### Permissions (the one thing to get right)

The api container runs as **uid 1001**, so the host directory behind
`DB_BACKUP_HOST_PATH` must be writable by that uid:

```bash
sudo chown -R 1001:1001 "${DB_BACKUP_HOST_PATH:-./backups}"
```

`scripts/setup-env.sh` prepares the default `./backups` dir for you when it
can. If the dir is unwritable, the api logs a clear warning, emits one
`backup_failed` alert, and **disables backups without affecting the api
itself**, backups being broken never takes the API down.

**Upgrading from the `db-backup` sidecar?** The sidecar wrote as root, so an
existing backups directory is probably root-owned, run the `chown` above
once, then `docker compose up -d --remove-orphans` (removes the leftover
sidecar container; your existing dumps stay valid and rotation picks them up).

## Turning it off

Set `DB_BACKUP_ENABLED=false` in `.env` and `docker compose up -d api`.
Nothing else depends on it. You can still use the manual
`scripts/backup-db.sh` / cron path from `docs/OPS-BACKUP-RECOVERY.md` instead
— e.g. if you want dumps pushed directly to a NAS/off-host target rather than
a local directory.

## Configuration (`.env`)

All optional, sane defaults ship if you don't set them (see `.env.example`):

| Variable | Default | Meaning |
|---|---|---|
| `DB_BACKUP_ENABLED` | `true` | Set `false` to disable the built-in job entirely. |
| `DB_BACKUP_HOST_PATH` | `./backups` | Host directory dumps are written to (bind-mounted read-write to `/backups` in the api container). **Put this on a different disk than `MEDIA_HOST_PATH`** where practical, a live-disk failure shouldn't also destroy your backups. Must be writable by uid 1001. |
| `DB_BACKUP_SCHEDULE` | `03:15` | Daily dump time, local wall clock `HH:MM` (in `TZ`). Legacy sidecar values (`@daily`, or a simple daily cron like `15 3 * * *`) are still accepted and mapped to the same daily behaviour. |
| `TZ` | `America/Los_Angeles` | Timezone the schedule (and dump filenames) use. |
| `DB_BACKUP_KEEP_DAYS` | `7` | Daily dumps to retain. |
| `DB_BACKUP_KEEP_WEEKS` | `4` | Weekly dumps to retain. |
| `DB_BACKUP_KEEP_MONTHS` | `0` | Monthly dumps to retain (`0` disables the monthly tier). |

To change any of these on a running stack: edit `.env`, then
`docker compose up -d api` (recreates just the api).

## Verifying it's working

```bash
cd /opt/crumb/app   # or wherever docker-compose.yml lives
docker compose logs api | grep -i "backup"     # "built-in DB backup job started", "database backup written"
ls -lh "${DB_BACKUP_HOST_PATH:-./backups}"/daily/  # crumb-<date>.sql.gz + crumb-latest.sql.gz symlink
zcat "${DB_BACKUP_HOST_PATH:-./backups}"/last/crumb-latest.sql.gz | head -3   # looks like pg_dump SQL
```

An on-demand dump without waiting for the schedule: restart the api when the
newest dump is older than ~25 h (`docker compose restart api` → boot catch-up
runs), or just take a manual one with `scripts/backup-db.sh`, the built-in
rotation won't touch it.

## Restoring

The built-in job's dumps are plain `pg_dump --no-owner --no-privileges` gzip
files (schema + data statements, **not** `--clean`/`--if-exists`, unlike
`scripts/backup-db.sh`'s dumps, unchanged from the old sidecar's format).
That means restoring cleanly needs an *empty* target database, not one with
the existing schema still in it:

**Recreate the database, then restore (matches a real disaster-recovery
restore):**

```bash
cd /opt/crumb/app
docker compose stop recorder api            # stop writers first

# Find the dump you want (the *-latest.sql.gz symlink is the newest):
ls -lh "${DB_BACKUP_HOST_PATH:-./backups}"/daily/

docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d postgres -c \
  "DROP DATABASE \"${POSTGRES_DB}\"; CREATE DATABASE \"${POSTGRES_DB}\" OWNER \"${POSTGRES_USER}\";"

gunzip -c "${DB_BACKUP_HOST_PATH:-./backups}/daily/<dump-file>.sql.gz" \
  | docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"

docker compose up -d recorder api           # reconcile re-indexes on-disk segments
```

(`scripts/restore-db.sh` expects `--clean --if-exists` dumps from
`scripts/backup-db.sh`; for the built-in job's dumps use the empty-database
path above.)

After restoring, always bring `recorder`/`api` back up so the recorder's
startup reconciliation re-indexes any segment files written to disk after the
restored dump's timestamp (see `docs/OPS-BACKUP-RECOVERY.md` for the full
per-failure-mode runbook and the tested-restore drill, **run that drill on a
spare host before you rely on this in production**).

## Off-host copies

The built-in backup job protects you against **losing the database** (bad
migration, `DROP TABLE`, disk corruption, `docker volume rm` fat-finger). It
does **not** protect you against **losing the host**, the dumps in
`DB_BACKUP_HOST_PATH` still live on the same box as `postgres`, the
recordings, and everything else. A fire, theft, or dead PSU takes out the
segments index, the footage, *and* the backups together.

**On-host-only is a fine, accepted posture** if this is a single-box home
install and you've made your peace with "if the box dies, I've lost the
video, so losing the DB backup too doesn't change the outcome." Not every
install needs disaster resilience against total hardware loss. If that's you,
stop here, you don't need anything below.

If you *do* want a copy that survives losing the whole host, pick **one** of
these two options:

### Option 1, point `DB_BACKUP_HOST_PATH` at a NAS/NFS mount (simplest)

No extra container, no new config. Mount a NAS share (NFS, SMB via a CIFS
mount, etc.) on the host and point the existing variable at it:

```bash
# .env
DB_BACKUP_HOST_PATH=/mnt/nas/crumb-db-backups
```

The api writes its daily/weekly/monthly dumps straight to that mount —
they're off-host the moment `pg_dump` finishes, with no sync step, no second
copy to keep track of, and no extra failure mode. This is the recommended
default for anyone with a NAS already on the network. The mount must be
writable by uid 1001 (see Permissions above) and reliably present at boot —
an unmounted path just looks unwritable to the api, which disables backups
with a warning (and a `backup_failed` alert) rather than crashing.

### Option 2, `backup-offsite` compose service (rclone, opt-in via profile)

If you don't have a mountable NAS share, or you want backups pushed to S3/B2/
SFTP/a remote server instead, an optional `backup-offsite` service is defined
in `docker-compose.yml`. It's gated behind the `offsite` Compose profile, so
it is **completely absent** from a stock `docker compose up -d`, nothing
about the default install changes.

Opt in:

```bash
# 1. Generate an rclone config (interactive wizard, pick your backend:
#    SFTP, S3, Backblaze B2, Google Drive, another NAS, ~70 backends total).
docker run --rm -it -v "$(pwd)/rclone.conf:/config/rclone/rclone.conf" \
  rclone/rclone:1 config
#    (this writes ./rclone.conf in the repo dir, keep it OUT of git; it holds
#    credentials, same trust level as .env)

# 2. Add to .env:
BACKUP_OFFSITE_REMOTE=mynas:crumb-backups   # remote:path, must match a
                                             # remote name from rclone.conf
BACKUP_OFFSITE_SCHEDULE=15 5 * * *          # 5-field cron; default is
                                             # 05:15 local, 2h after the
                                             # built-in job's 03:15 dump
BACKUP_OFFSITE_RCLONE_CONF=./rclone.conf    # path to the file from step 1

# 3. Start it (note the --profile flag, a plain `docker compose up -d`
#    will NOT start this service):
docker compose --profile offsite up -d backup-offsite

# 4. Verify:
docker compose --profile offsite logs -f backup-offsite
```

The container runs `rclone sync /backups <remote>` on the cron schedule
(busybox `crond`, bundled in the `rclone/rclone` image, no extra scheduler
package). It mounts `DB_BACKUP_HOST_PATH` **read-only**: it only ever pushes
outward, never deletes or restores from the remote. Leaving
`BACKUP_OFFSITE_REMOTE` unset makes the container idle (a clear log line, no
crash loop) even if you start it with `--profile offsite`, so opting into
the profile and forgetting to configure the remote fails safe, not silently.

To stop syncing off-host again: `docker compose stop backup-offsite` (or
just don't pass `--profile offsite` on your next `up`).

### The `backup_failed` alert needs the api to actually SEE the dumps

The system-health `backup_failed` alert has two triggers: the built-in job
reporting its own failed run **directly**, and a freshness watchdog that
fires when the newest dump under the api's `/backups` mount
(`DB_BACKUP_HOST_PATH`) looks stale. If your backups are produced by
something **other** than the built-in job, e.g. your own host cron running
`scripts/backup-db.sh` straight to a different directory, or an external tool
entirely, set `DB_BACKUP_ENABLED=false` and point `DB_BACKUP_HOST_PATH` at
whatever directory that external mechanism writes its dumps to, so the api's
staleness check lines up with where the real dumps land. If it points
somewhere the dumps *aren't*, the api sees an empty/stale directory and pages
you a false `backup_failed`, not because backups actually stopped, but
because it's looking in the wrong place.

## Relationship to `scripts/backup-db.sh` / `docs/OPS-BACKUP-RECOVERY.md`

Both approaches dump the same database in a compatible format and can be used
together or separately:

- **Built-in api job (this doc)**, zero-setup, on by default, local
  directory, fixed rotation tiers, direct failure alerts; the right default
  for most installs.
- **`scripts/backup-db.sh` + host cron (`docs/OPS-BACKUP-RECOVERY.md`)** —
  manual opt-in, more flexible (e.g. dump straight to a NAS mount, custom
  retention math, wrap in your own alerting), useful if you want backups
  pushed somewhere the api's bind mount doesn't reach directly.

Running both is harmless (they just produce two sets of dumps, the built-in
rotation never deletes the script's differently-named files); most operators
only need one.

## Production note

**If you have an existing production stack**, the built-in job only runs once
the api image containing it is deployed there, it is not automatic just
because it landed in the repo. After deploying: make sure the backups dir is
writable by uid 1001 (see Permissions), run
`docker compose up -d --remove-orphans` to retire any old `db-backup` sidecar
container, and confirm a dump has actually landed.
