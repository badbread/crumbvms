#!/usr/bin/env bash
# Generate Docker secret files for the Crumb secrets overlay (audit Risk #9).
#
# Creates ./secrets/{db_password,database_url,jwt_secret,admin_password} with
# cryptographically-random values, then locks them down (dir 700, files 600).
# Pair with docker-compose.secrets.example.yml — see that file's header.
#
# Idempotent: existing files are kept unless --force is given. The generated
# database_url embeds the generated db_password so Postgres and the apps agree.
#
# Env overrides: POSTGRES_USER (default crumb), POSTGRES_DB (default crumb),
# POSTGRES_HOST (default postgres), POSTGRES_PORT (default 5432).
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

cd "$(dirname "$0")/.."
SECRETS_DIR="./secrets"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

PGUSER="${POSTGRES_USER:-crumb}"
PGDB="${POSTGRES_DB:-crumb}"
PGHOST="${POSTGRES_HOST:-postgres}"
PGPORT="${POSTGRES_PORT:-5432}"

gen_hex() { openssl rand -hex "${1:-24}"; }

write_secret() {
  local name="$1" value="$2" path="$SECRETS_DIR/$1"
  if [[ -s "$path" && "$FORCE" -ne 1 ]]; then
    echo "  keep   $name (exists; use --force to regenerate)"
    return
  fi
  printf '%s' "$value" > "$path"
  chmod 600 "$path"
  echo "  wrote  $name"
}

echo "Generating Crumb secrets in $SECRETS_DIR/ ..."

# DB password first; database_url depends on it. If db_password already exists
# and we're not forcing, reuse it so database_url stays consistent.
if [[ -s "$SECRETS_DIR/db_password" && "$FORCE" -ne 1 ]]; then
  DB_PASSWORD="$(cat "$SECRETS_DIR/db_password")"
else
  DB_PASSWORD="$(gen_hex 24)"
fi

write_secret db_password   "$DB_PASSWORD"
write_secret database_url  "postgresql://${PGUSER}:${DB_PASSWORD}@${PGHOST}:${PGPORT}/${PGDB}"
write_secret jwt_secret    "$(gen_hex 32)"
write_secret admin_password "$(gen_hex 16)"

echo "Done. Deploy with:"
echo "  cp docker-compose.secrets.example.yml docker-compose.secrets.yml"
echo "  docker compose -f docker-compose.yml -f docker-compose.secrets.yml up -d"
echo
echo "Bootstrap admin password (save it, then it is only on disk in ./secrets/admin_password):"
echo "  $(cat "$SECRETS_DIR/admin_password")"
