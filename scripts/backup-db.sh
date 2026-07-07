#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Crumb — Postgres backup
#
# pg_dumps the Crumb database to a gzipped, timestamped file, then prunes
# dumps older than the retention window. The DB holds the segment index — the
# SOLE source of truth for all footage. Lose it and the .mp4 files on disk are
# unplayable (no camera/time/keyframe mapping). This dump is your recovery path.
# See docs/OPS-BACKUP-RECOVERY.md.
#
# Cron-friendly: idempotent, logs to stdout with timestamps, exits non-zero on
# any failure so cron/monitoring can alert.
#
# Usage:
#   scripts/backup-db.sh                 # dump to ./backups (or $BACKUP_DIR)
#   BACKUP_DIR=/mnt/nas/crumb-backups scripts/backup-db.sh
#   RETENTION_DAYS=14 scripts/backup-db.sh
#
# Cron (daily 03:15 America/Los_Angeles), append a log:
#   15 3 * * *  cd /opt/crumb/app && BACKUP_DIR=/mnt/recordings/crumb/db-backups \
#                 scripts/backup-db.sh >> /var/log/crumb-backup.log 2>&1
#   (set CRON_TZ=America/Los_Angeles at the top of the crontab)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Resolve repo root from this script's location so cron can run it from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# ── config (override via env) ────────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-${REPO_ROOT}/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
COMPOSE_BIN="${COMPOSE_BIN:-docker compose}"
PG_SERVICE="${PG_SERVICE:-postgres}"

log() { printf '%s [backup-db] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# ── load .env for POSTGRES_USER / POSTGRES_DB ────────────────────────────────
# These are the creds the bundled postgres container was initialised with; they
# also identify the role/db for pg_dump. We read them WITHOUT exporting the whole
# .env (which may contain secrets we don't need here).
if [[ -f .env ]]; then
  POSTGRES_USER="${POSTGRES_USER:-$(grep -E '^POSTGRES_USER=' .env | head -n1 | cut -d= -f2-)}"
  POSTGRES_DB="${POSTGRES_DB:-$(grep -E '^POSTGRES_DB=' .env | head -n1 | cut -d= -f2-)}"
fi
POSTGRES_USER="${POSTGRES_USER:-crumb}"
POSTGRES_DB="${POSTGRES_DB:-crumb}"

# ── preflight ────────────────────────────────────────────────────────────────
mkdir -p "${BACKUP_DIR}" || die "cannot create backup dir ${BACKUP_DIR}"

# Confirm the postgres service is actually up before attempting a dump. If this
# deployment uses a REMOTE Postgres (docker-compose.override), the bundled
# service won't exist — fall back to a direct pg_dump via DATABASE_URL.
TS="$(date '+%Y%m%d-%H%M%S')"
OUT="${BACKUP_DIR}/crumb-${POSTGRES_DB}-${TS}.sql.gz"
TMP="${OUT}.partial"

dump_via_compose() {
  log "dumping db '${POSTGRES_DB}' as role '${POSTGRES_USER}' via '${COMPOSE_BIN} exec ${PG_SERVICE}'"
  # -T: no TTY (required when run from cron). --clean --if-exists makes the dump
  # safe to restore over an existing schema. Pipe straight to gzip; pipefail
  # ensures a pg_dump failure mid-stream aborts the whole pipeline.
  ${COMPOSE_BIN} exec -T "${PG_SERVICE}" \
    pg_dump --clean --if-exists --no-owner --no-privileges \
            -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    | gzip -c > "${TMP}"
}

dump_via_url() {
  command -v pg_dump >/dev/null 2>&1 \
    || die "no local '${PG_SERVICE}' container and pg_dump not on PATH — install postgresql-client or run on the DB host"
  [[ -n "${DATABASE_URL:-}" ]] \
    || die "no local '${PG_SERVICE}' container and DATABASE_URL not set — cannot reach a remote DB"
  log "dumping via DATABASE_URL (remote/external Postgres)"
  pg_dump --clean --if-exists --no-owner --no-privileges "${DATABASE_URL}" \
    | gzip -c > "${TMP}"
}

# Is the bundled postgres service running?
if ${COMPOSE_BIN} ps --services --filter "status=running" 2>/dev/null | grep -qx "${PG_SERVICE}"; then
  dump_via_compose
else
  log "bundled '${PG_SERVICE}' service not running — trying remote DATABASE_URL"
  # shellcheck disable=SC1091
  [[ -f .env ]] && set -a && . ./.env && set +a || true
  dump_via_url
fi

# ── integrity: a valid gzip dump is non-trivially sized and decompresses ──────
[[ -s "${TMP}" ]] || die "dump file is empty — backup FAILED, not promoting partial"
gzip -t "${TMP}" || die "gzip integrity check failed on ${TMP} — backup FAILED"

mv "${TMP}" "${OUT}"
SIZE="$(du -h "${OUT}" | cut -f1)"
log "wrote ${OUT} (${SIZE})"

# ── prune old backups ────────────────────────────────────────────────────────
log "pruning *.sql.gz older than ${RETENTION_DAYS} days in ${BACKUP_DIR}"
PRUNED="$(find "${BACKUP_DIR}" -maxdepth 1 -name 'crumb-*.sql.gz' -type f -mtime "+${RETENTION_DAYS}" -print -delete | wc -l | tr -d ' ')"
log "pruned ${PRUNED} old backup(s)"

# Also clean up any stale .partial files from previous interrupted runs.
find "${BACKUP_DIR}" -maxdepth 1 -name 'crumb-*.sql.gz.partial' -type f -mtime +1 -delete 2>/dev/null || true

REMAINING="$(find "${BACKUP_DIR}" -maxdepth 1 -name 'crumb-*.sql.gz' -type f | wc -l | tr -d ' ')"
log "OK — ${REMAINING} backup(s) retained in ${BACKUP_DIR}"
