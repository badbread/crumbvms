# Crumb, Backup & Disaster Recovery Runbook

This is the operator runbook for keeping Crumb recoverable. Read it before
your first deploy, and **test the restore on a spare host before you rely on
it** (see the pre-deployment checklist at the bottom).

Commands assume the stack lives at `/opt/crumb/app` (the compose project
root, where `docker-compose.yml` and `.env` live). Adjust paths to your install.

---

## Why the database is the thing you must back up

Crumb records video as short MP4 segments on disk (`/data/live`,
`/data/archive`). But a bare `.mp4` on disk is **not** playable footage on its
own, the **Postgres `segments` index is the sole source of truth** that maps
each file to *which camera*, *what wall-clock time range*, *which storage*, and
*where its keyframes are*. The clients, timeline,
playback, and export all query that index; they never scan the filesystem.

Consequences:

- **Lose the database → the footage on disk is effectively unplayable.** The
  recorder's startup reconciliation (`docs/RECORDER-CORRECTNESS.md` item 9) can
  re-index *files it can still find on the configured storages*, but it cannot
  recover bookmarks, users, views, camera config, retention policy, or motion
  metadata. Reconciliation is a partial safety net, **not** a backup.
- **The video files are large and change constantly; the database is small and
  changes slowly.** So the strategy is: back up the database often and off-host;
  treat the video files as separately-protected bulk storage.

**Backup target = the Postgres database.** Video files are protected separately
(RAID / ZFS / NAS snapshots on the storage volumes) and are out of scope for the
db backup script.

---

## What backs up, and how

`scripts/backup-db.sh` runs `pg_dump` (via `docker compose exec -T postgres`, or
directly over `DATABASE_URL` for a remote DB), gzips a timestamped dump into a
backups directory, verifies the gzip, and prunes dumps older than the retention
window (default 30 days).

```bash
cd /opt/crumb/app
scripts/backup-db.sh                      # → ./backups/crumb-crumb-<ts>.sql.gz
BACKUP_DIR=/mnt/recordings/crumb/db-backups scripts/backup-db.sh   # off the live disk
RETENTION_DAYS=14 scripts/backup-db.sh    # shorter retention
```

Properties (so it's safe under cron):

- **Idempotent / atomic**, writes to a `.partial` file, verifies, then renames.
- **Verified**, fails (non-zero exit) if the dump is empty or the gzip is corrupt.
- **Logged**, timestamped lines to stdout; redirect to a log in cron.
- **Self-pruning**, deletes `crumb-*.sql.gz` older than `RETENTION_DAYS`.

### Backup schedule (cron)

Put backups on a **different disk than the live recordings** (ideally the NAS or
archive volume) so a live-disk failure doesn't take the backups with it.

```cron
# /etc/crontab or `crontab -e` on the Crumb host.
# Run as the user that can talk to docker. Times are local; pin the TZ:
CRON_TZ=America/Los_Angeles
15 3 * * *  cd /opt/crumb/app && BACKUP_DIR=/mnt/recordings/crumb/db-backups scripts/backup-db.sh >> /var/log/crumb-backup.log 2>&1
```

Daily at 03:15 America/Los_Angeles, 30-day retention. Verify after the first
night: `ls -lh /mnt/recordings/crumb/db-backups`.

> Off-host copy: for real disaster resilience, sync the backups directory to a
> second machine or object store (e.g. nightly `rclone copy` / `aws s3 sync` of
> `BACKUP_DIR`). A backup that only exists on the host you're trying to recover
> isn't a backup.

---

## How to restore

`scripts/restore-db.sh` restores a chosen gzipped dump. It is **destructive**
(`pg_dump --clean --if-exists` drops and recreates objects) and guards against
accidents by requiring you to type the database name (or pass `--yes`).

```bash
cd /opt/crumb/app
docker compose stop recorder api                 # stop writers first
scripts/restore-db.sh backups/crumb-crumb-20260615-031500.sql.gz
docker compose up -d recorder api                # reconcile re-indexes on-disk segments
```

Always stop `recorder` and `api` before restoring so nothing writes mid-restore.
After restart, the recorder's reconciliation re-indexes any segment files on disk
that the restored index doesn't know about, so footage recorded *after* the
backup but still on disk is recovered automatically.

### Tested-restore drill (do this BEFORE you need it)

1. Spin up a throwaway host / VM with Docker.
2. Copy the repo + a recent `*.sql.gz` dump to it.
3. `scripts/setup-env.sh` to get a `.env`, then `docker compose up -d postgres`.
4. `scripts/restore-db.sh --yes <dump>.sql.gz`.
5. `docker compose up -d api` and confirm you can log in and the camera list
   loads. Confirm row counts: `docker compose exec -T postgres psql -U crumb
   -d crumb -c '\dt'` and a `SELECT count(*) FROM segments;`.

If the drill fails, fix it now, not during a real outage.

---

## Per-failure-mode recovery

### A. Postgres corrupt / won't start (index damaged)

Symptoms: `postgres` container crash-loops; api/recorder log connection or query
errors; `docker compose logs postgres` shows corruption / WAL errors.

```bash
cd /opt/crumb/app
docker compose stop recorder api
# Stop AND REMOVE the postgres container. A merely-stopped container still holds a
# reference to its data volume, which makes the `docker volume rm` in the fallback
# below fail with "volume is in use". `up -d postgres` recreates the container.
docker compose rm -sf postgres

# Resolve the ACTUAL Postgres data volume name. On a stock install the Compose
# project is `crumbvms`, so the volume is `crumbvms_crumb_pgdata` — but resolve
# it rather than hardcode, in case your project name differs.
PGVOL=$(docker volume ls -q | grep crumb_pgdata | head -1)
echo "Postgres data volume: $PGVOL"

# Move the corrupt data volume aside (don't delete until recovery is confirmed).
docker volume rename "$PGVOL" "${PGVOL}_corrupt_$(date +%Y%m%d)" \
  || { docker run --rm -v "$PGVOL":/from -v "${PGVOL}_corrupt":/to alpine \
         sh -c 'cp -a /from/. /to/' && docker volume rm "$PGVOL" ; }
         # ^ if your Docker can't rename volumes: copy the data aside, then remove
         #   the original so the next `up -d` recreates it empty.

docker compose up -d postgres             # recreates an empty data volume; api/recorder
                                          # apply db/migrations on their next boot (NOT postgres initdb)
scripts/restore-db.sh --yes backups/<most-recent>.sql.gz
docker compose up -d recorder api         # reconcile re-indexes on-disk segments
```

You lose only the rows written between the last good backup and the failure; the
recorder re-indexes any segments still on disk on next boot.

### B. Live disk full (recording stalls / segments lost)

Symptoms: recorder logs write/ENOSPC errors; new segments stop; motion gaps.

```bash
df -h                                      # confirm which volume is full
# Crumb's live retention deletes oldest live segments automatically, but a
# disk can still fill if retention is mis-sized or archive is backed up.
docker compose logs --tail=100 recorder    # confirm it's disk, not GPU/stream

# Immediate relief, reclaim space WITHOUT touching the DB or archive:
#  * Free non-Crumb space on the volume, OR
#  * Lower the live-retention window for the noisiest cameras in the UI/config,
#    then let retention prune on the next tick.
# Do NOT hand-delete .mp4 files: the retention path deletes the FILE then the ROW
# (docs/RECORDER-CORRECTNESS.md item 10). Deleting files behind its back leaves
# dangling index rows (playback 404s) until the next reconcile.
```

Longer term: move `ARCHIVE_HOST_PATH` to bulk/NAS storage and/or grow the live
volume. The DB is unaffected by a full *live* disk as long as Postgres lives on a
volume with free space (another reason to externalize Postgres, see below).

### C. Recorder crash / OOM

Symptoms: `recorder` container restarting; gap in recordings during the crash.

```bash
docker compose ps                          # is recorder up? restart count?
docker compose logs --tail=200 recorder    # look for panic / OOM-kill
# The recorder is memory-capped at 4g in docker-compose.yml; an OOM there is a
# clean container kill, not a host outage. `restart: unless-stopped` brings it
# back; startup reconciliation re-indexes any segment files written right before
# the crash. No DB restore needed, the index is intact.
docker compose up -d recorder              # if it's down for any reason
```

If it OOM-loops, reduce concurrent GPU decode (`MAX_GPU_DECODE_SESSIONS`) or
camera count, or raise the `deploy.resources.limits.memory` cap in compose. A
crash costs at most the in-flight segment, not the index.

### D. Power loss / unclean shutdown

On boot, `restart: unless-stopped` brings all services back. Sequence:

```bash
cd /opt/crumb/app
docker compose ps                          # postgres healthy? recorder/api up?
docker compose logs --tail=50 postgres     # confirm Postgres recovered its WAL cleanly
```

Postgres replays its WAL and comes up consistent (this is why the index is in a
real database, not flat files). The recorder reconciles on boot and re-indexes
any segments flushed to disk before the power cut. Verify recent footage plays in
a client. If Postgres does **not** recover cleanly, treat it as **failure mode A**
(restore from the last backup).

### E. Total host loss (hardware dead)

This is the scenario that justifies off-host backups + (ideally) remote Postgres.

```bash
# On a replacement host:
git clone <repo> /opt/crumb/app && cd /opt/crumb/app
scripts/setup-env.sh                        # or copy the saved .env from secure storage
# Restore storage volumes if you snapshot them (live/archive), then:
docker compose up -d postgres
scripts/restore-db.sh --yes /path/to/offhost/backups/<most-recent>.sql.gz
docker compose up -d
```

Footage on disk that survived (e.g. archive on a separate NAS) is re-indexed by
reconciliation. Footage on a dead live disk is gone, protect the live volume
with RAID/ZFS and archive aggressively to bulk/NAS if that footage matters.

---

## Reducing the single point of failure: external Postgres

The biggest durability win is moving Postgres **off the recording host** so a
recorder-host failure can't take the index with it, and so the DB can be backed
up / PITR'd independently. No code change is needed, only `DATABASE_URL`.

See **`docker-compose.override.example.yml`** for the mechanism. Summary:

1. Stand up Postgres on a dedicated host / VM / managed service.
2. **Provision the schema once** (the bundled container did this via
   `db/migrations` on first init; a remote DB will not):
   ```bash
   for f in db/migrations/*.sql; do
     psql "postgresql://crumb:PASS@REMOTE_HOST:5432/crumb" -v ON_ERROR_STOP=1 -f "$f"
   done
   ```
3. `cp docker-compose.override.example.yml docker-compose.override.yml`.
4. Point `DATABASE_URL` in `.env` at the remote host.
5. `docker compose up -d`, the bundled `postgres` service stays parked; api +
   recorder connect to the remote DB.

`scripts/backup-db.sh` / `restore-db.sh` automatically fall back to operating
over `DATABASE_URL` when the bundled `postgres` service isn't running, so the
same scripts and the same cron line keep working against the remote DB (they need
`pg_dump`/`psql` on PATH, install `postgresql-client` on the host running cron).

---

## Pre-deployment checklist (per install)

- [ ] `scripts/setup-env.sh` run; `.env` has strong generated secrets, mode 600.
- [ ] `.env` is **not** committed (pre-commit hook installed:
      `git config core.hooksPath .githooks`).
- [ ] Backup cron installed, `BACKUP_DIR` on a **different disk** than live
      recordings, retention set, TZ pinned to `America/Los_Angeles`.
- [ ] Backups synced **off-host** (NAS / object store).
- [ ] **Tested-restore drill performed on a spare host**, login + camera list +
      `SELECT count(*) FROM segments;` verified after restore.
- [ ] Decided on Postgres topology (bundled vs external) and, if external,
      schema provisioned and `DATABASE_URL` pointed at it.
- [ ] Live volume protected (RAID/ZFS); archive on bulk/NAS if footage must
      survive a single-disk loss.
