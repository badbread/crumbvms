#!/usr/bin/env bash
# CrumbVMS — nightly PostgreSQL backup to the ARCHIVE disk.
#
# Why: the `segments` table is the sole map of ~490k mp4 files -> camera/time.
# pgdata lives on the OS disk (a SPOF); this writes a ~20 MB gzipped logical dump
# onto /mnt/recordings (a SEPARATE physical disk that holds the footage), so an
# OS-disk loss does not take the only copy of the index with it.
#
# Restore drill: gunzip -c crumb-db-<ts>.sql.gz | psql -U crumb -d <fresh_db>
set -euo pipefail

APP_DIR=/opt/crumb/app
BACKUP_DIR=/mnt/recordings/crumb-db-backups
KEEP_DAYS=30
PG_USER=crumb
PG_DB=crumb

mkdir -p "$BACKUP_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
out="$BACKUP_DIR/crumb-db-${ts}.sql.gz"
tmp="${out}.tmp"

cd "$APP_DIR"

# Full logical dump of the database, gzipped. Streamed straight to the archive disk.
docker compose exec -T postgres pg_dump -U "$PG_USER" -d "$PG_DB" | gzip -c > "$tmp"

# Integrity gates BEFORE we publish or prune anything: a non-trivial size and a
# valid gzip stream. On failure, keep prior backups untouched and exit non-zero
# (so the systemd unit + any alerting notices).
sz="$(stat -c%s "$tmp")"
if [ "$sz" -lt 1000000 ]; then
  echo "FATAL: dump is only ${sz} bytes (<1MB) — aborting, prior backups left intact" >&2
  rm -f "$tmp"
  exit 1
fi
gzip -t "$tmp"
mv -f "$tmp" "$out"

# Retention: keep the last KEEP_DAYS days of backups.
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'crumb-db-*.sql.gz' -mtime "+${KEEP_DAYS}" -delete

count="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'crumb-db-*.sql.gz' | wc -l)"
echo "OK: wrote ${out} ($(du -h "$out" | cut -f1)); ${count} backups retained in ${BACKUP_DIR}"
