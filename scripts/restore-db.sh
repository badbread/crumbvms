#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Crumb — Postgres restore (DESTRUCTIVE)
#
# Restores the Crumb database from a gzipped pg_dump produced by
# scripts/backup-db.sh. This OVERWRITES the current segment index. Read
# docs/OPS-BACKUP-RECOVERY.md before running in anger.
#
# Because the dump is taken with `pg_dump --clean --if-exists`, restoring drops
# and recreates every object — any rows recorded since the backup are LOST.
#
# Usage:
#   scripts/restore-db.sh backups/crumb-crumb-20260615-031500.sql.gz
#   scripts/restore-db.sh --yes backups/<dump>.sql.gz      # skip the prompt (automation)
#
# Recommended order of operations (so the recorder doesn't write mid-restore):
#   docker compose stop recorder api
#   scripts/restore-db.sh backups/<dump>.sql.gz
#   docker compose up -d recorder api
#   # The recorder's startup reconciliation re-indexes any on-disk segments that
#   # the restored index is missing (see docs/RECORDER-CORRECTNESS.md item 9).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

COMPOSE_BIN="${COMPOSE_BIN:-docker compose}"
PG_SERVICE="${PG_SERVICE:-postgres}"

log() { printf '%s [restore-db] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

ASSUME_YES=0
DUMP=""
for arg in "$@"; do
  case "${arg}" in
    --yes|-y) ASSUME_YES=1 ;;
    -*)       die "unknown flag: ${arg}" ;;
    *)        DUMP="${arg}" ;;
  esac
done

[[ -n "${DUMP}" ]] || die "usage: scripts/restore-db.sh [--yes] <dump.sql.gz>"
[[ -f "${DUMP}" ]] || die "dump file not found: ${DUMP}"
gzip -t "${DUMP}" || die "'${DUMP}' is not a valid gzip file"

# ── creds ────────────────────────────────────────────────────────────────────
if [[ -f .env ]]; then
  POSTGRES_USER="${POSTGRES_USER:-$(grep -E '^POSTGRES_USER=' .env | head -n1 | cut -d= -f2-)}"
  POSTGRES_DB="${POSTGRES_DB:-$(grep -E '^POSTGRES_DB=' .env | head -n1 | cut -d= -f2-)}"
fi
POSTGRES_USER="${POSTGRES_USER:-crumb}"
POSTGRES_DB="${POSTGRES_DB:-crumb}"

# ── confirmation guard ───────────────────────────────────────────────────────
log "About to restore '${DUMP}'"
log "  → target database : ${POSTGRES_DB}"
log "  → target role     : ${POSTGRES_USER}"
log "  → THIS OVERWRITES the current segment index. Any footage recorded since"
log "    this dump was taken will be UNINDEXED (files may survive; reconcile re-adds them)."
if [[ "${ASSUME_YES}" -ne 1 ]]; then
  if [[ ! -t 0 ]]; then
    die "refusing to restore non-interactively without --yes (no TTY to confirm)"
  fi
  printf 'Type the database name (%s) to confirm restore: ' "${POSTGRES_DB}"
  read -r CONFIRM
  [[ "${CONFIRM}" == "${POSTGRES_DB}" ]] || die "confirmation did not match — aborting, nothing changed"
fi

# ── restore ──────────────────────────────────────────────────────────────────
restore_via_compose() {
  log "restoring via '${COMPOSE_BIN} exec ${PG_SERVICE}'"
  # ON_ERROR_STOP=1 makes psql abort + return non-zero on the first SQL error
  # instead of plowing through and leaving a half-restored DB.
  gunzip -c "${DUMP}" \
    | ${COMPOSE_BIN} exec -T "${PG_SERVICE}" \
        psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"
}

restore_via_url() {
  command -v psql >/dev/null 2>&1 \
    || die "no local '${PG_SERVICE}' container and psql not on PATH — install postgresql-client or run on the DB host"
  [[ -n "${DATABASE_URL:-}" ]] || die "no local '${PG_SERVICE}' container and DATABASE_URL not set"
  log "restoring via DATABASE_URL (remote/external Postgres)"
  gunzip -c "${DUMP}" | psql -v ON_ERROR_STOP=1 "${DATABASE_URL}"
}

if ${COMPOSE_BIN} ps --services --filter "status=running" 2>/dev/null | grep -qx "${PG_SERVICE}"; then
  restore_via_compose
else
  log "bundled '${PG_SERVICE}' service not running — trying remote DATABASE_URL"
  # shellcheck disable=SC1091
  [[ -f .env ]] && set -a && . ./.env && set +a || true
  restore_via_url
fi

log "restore complete from ${DUMP}"
log "Next: 'docker compose up -d recorder api' — startup reconciliation re-indexes any on-disk segments missing from the restored index."
