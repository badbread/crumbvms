#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Fresh-install smoke test for CrumbVMS.
#
# Proves that a from-scratch `docker compose up` boots a HEALTHY stack and the
# first-run flow works — the exact path a brand-new user follows per the README
# and docs/AI-INSTALL.md. Catches fresh-install regressions (e.g. the export-dir
# and Caddy-port ship-blockers found by hand) before a real user hits them.
#
# What it does, all self-contained + isolated (unique project name, ephemeral
# localhost api port, temp .env + media dir — safe to run alongside other stacks):
#   1. Generate a real .env with scripts/setup-env.sh (strong secrets), headless
#      admin seed.
#   2. Build the images from source + boot the whole stack
#      (docker-compose.yml + .build.yml + .smoke.yml).
#   3. Wait for the api /health to go green.
#   4. Assert: migrations applied, core services up, first-run admin login works,
#      JWT validates, the admin API responds, and no panic/FATAL in the logs.
#   5. Tear everything down (containers + volumes + temp dirs), always.
#
# Usage:  scripts/test/fresh-install-smoke.sh
# Exit:   0 = all checks passed; non-zero = a check failed (message says which).
#
# Requires: Docker + Compose v2.24+ (for the `!override` tag in .smoke.yml).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

PROJECT="crumbsmoke$$"
ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/crumb-smoke-env.XXXXXX")"
MEDIA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/crumb-smoke-media.XXXXXX")"
BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/crumb-smoke-backups.XXXXXX")"
ADMIN_PW="smoke-admin-$$"
COMPOSE=(docker compose -p "${PROJECT}"
  -f docker-compose.yml -f docker-compose.build.yml -f docker-compose.smoke.yml
  --env-file "${ENV_FILE}")

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; FAILED=1; }
info() { printf '\n== %s ==\n' "$*"; }
FAILED=0

cleanup() {
  info "teardown"
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${MEDIA_DIR}" "${BACKUP_DIR}" "${ENV_FILE}" || true
}
trap cleanup EXIT

# ── 1. generate .env (real secrets) + point storage at temp dirs ─────────────
info "generate .env (scripts/setup-env.sh)"
ENV_FILE="${ENV_FILE}" ./scripts/setup-env.sh --force >/dev/null
# Headless admin seed with a known password so we can log in; isolate storage.
sed -i \
  -e "s|^SEED_ADMIN_PASSWORD=.*|SEED_ADMIN_PASSWORD=${ADMIN_PW}|" \
  -e "s|^MEDIA_HOST_PATH=.*|MEDIA_HOST_PATH=${MEDIA_DIR}|" \
  -e "s|^DB_BACKUP_HOST_PATH=.*|DB_BACKUP_HOST_PATH=${BACKUP_DIR}|" \
  "${ENV_FILE}"
grep -q "^DB_BACKUP_HOST_PATH=" "${ENV_FILE}" || echo "DB_BACKUP_HOST_PATH=${BACKUP_DIR}" >> "${ENV_FILE}"
# Pin a NON-UTC container timezone so step 4e always exercises the
# localtime-vs-UTC segment-timestamp trap (regression 2026-07-03: ffmpeg's
# `-strftime 1` expands filenames in LOCAL time; with TZ set on the recorder,
# every segment row landed hours in the past and the live index froze). With
# the recorder's in-child TZ=UTC pin in place this is harmless; if that pin
# ever regresses, 4e's freshness check fails loudly.
echo "TZ=America/Los_Angeles" >> "${ENV_FILE}"
# The api's built-in backup job writes here as uid 1001 (mktemp dirs are 700
# and owned by whoever runs this script, so the container couldn't write).
chown 1001:1001 "${BACKUP_DIR}" 2>/dev/null || chmod 777 "${BACKUP_DIR}"
# Same for the media dir: the recorder (also uid 1001) must create
# /data/live/<camera-id>/ under it once step 4e starts recording.
chown 1001:1001 "${MEDIA_DIR}" 2>/dev/null || chmod 777 "${MEDIA_DIR}"
# shellcheck disable=SC1090
PG_USER="$(grep -E '^POSTGRES_USER=' "${ENV_FILE}" | cut -d= -f2)"
PG_DB="$(grep -E '^POSTGRES_DB=' "${ENV_FILE}" | cut -d= -f2)"
pass ".env generated (project ${PROJECT}, media ${MEDIA_DIR})"

# ── 2. build + boot the whole stack from source ──────────────────────────────
info "build + up (this compiles the Rust images; first run is slow)"
"${COMPOSE[@]}" up -d --build

# ── 3. wait for api /health ──────────────────────────────────────────────────
info "wait for api /health"
API_HP="$("${COMPOSE[@]}" port api 8080 2>/dev/null || true)"
if [ -z "${API_HP}" ]; then fail "api port not published (compose port api 8080 empty)"; exit 1; fi
API_URL="http://${API_HP}"
ok=0
for i in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/health" 2>/dev/null || true)"
  if [ "${code}" = "200" ]; then ok=1; break; fi
  sleep 2
done
if [ "${ok}" = "1" ]; then pass "api /health = 200 (${API_URL})"; else
  fail "api never became healthy at ${API_URL}"
  "${COMPOSE[@]}" ps; "${COMPOSE[@]}" logs --tail 40 api; exit 1
fi

# ── 4a. migrations applied ───────────────────────────────────────────────────
info "schema migrations applied"
MIG="$("${COMPOSE[@]}" exec -T postgres psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
  'select count(*) from schema_migrations' 2>/dev/null | tr -d '[:space:]' || echo 0)"
if [ "${MIG:-0}" -gt 20 ] 2>/dev/null; then pass "schema_migrations = ${MIG}"; else
  fail "expected >20 applied migrations, got '${MIG}'"; fi

# ── 4b. core services running ────────────────────────────────────────────────
info "core services running"
# go2rtc is EMBEDDED in the recorder container (no separate service) — the
# recorder's own supervision + the api reconcile loop cover it.
for svc in postgres recorder api; do
  st="$("${COMPOSE[@]}" ps -a --format '{{.Service}} {{.State}}' 2>/dev/null | awk -v s="${svc}" '$1==s{print $2}')"
  if [ "${st}" = "running" ]; then pass "${svc}: running"; else fail "${svc}: '${st}' (expected running)"; fi
done

# ── 4b2. motion RAM cache is writable by the (non-root) recorder ────────────
# The tmpfs `/cache` mount (docker-compose.yml) MUST be `mode: 01777` because
# the recorder runs as uid 1001, not root — see docs/MOTION-RECORDING.md. If a
# future compose edit drops that mode, the mount comes up root-owned 0755, the
# recorder's `create_dir_all(MOTION_CACHE_DIR/<camera>)` gets EACCES, and every
# Motion-mode camera silently falls back to recording continuously (the prod
# incident this check exists to catch — ~11h undetected, only noticed by eye).
# Proves the cache is actually usable, not just mounted: create+remove a dir
# under it as the container's own user.
info "motion RAM cache is writable by the recorder (tmpfs mode)"
if "${COMPOSE[@]}" exec -T recorder sh -c \
  'D="${MOTION_CACHE_DIR:-/cache/motion}"; mkdir -p "$D/.smoketest" && rmdir "$D/.smoketest"' \
  >/dev/null 2>&1; then
  pass "recorder can create+remove a dir under MOTION_CACHE_DIR"
else
  fail "recorder could NOT create a dir under MOTION_CACHE_DIR — the tmpfs mount \
is likely missing 'mode: 01777' (docker-compose.yml, recorder service, /cache tmpfs), \
so it mounted root-owned and the non-root recorder (uid 1001) gets EACCES; \
this is the exact failure mode that makes Motion-mode cameras silently record \
continuously (docs/MOTION-RECORDING.md)"
fi

# ── 4c. first-run admin login + JWT validation ───────────────────────────────
info "first-run admin login (seeded from SEED_ADMIN_PASSWORD)"
LOGIN="$(curl -s -X POST "${API_URL}/auth/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PW}\"}" 2>/dev/null || true)"
TOKEN="$(printf '%s' "${LOGIN}" | grep -oE '"token":"[^"]+"' | cut -d'"' -f4)"
if [ -n "${TOKEN}" ]; then pass "admin login returned a token"; else
  fail "admin login failed (response: $(printf '%s' "${LOGIN}" | head -c 120))"; fi

if [ -n "${TOKEN}" ]; then
  ME="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" "${API_URL}/auth/me" 2>/dev/null || true)"
  [ "${ME}" = "200" ] && pass "/auth/me = 200 (JWT validates)" || fail "/auth/me = ${ME} (expected 200)"

  CAMS="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" "${API_URL}/config/cameras" 2>/dev/null || true)"
  [ "${CAMS}" = "200" ] && pass "/config/cameras = 200 (admin API responds)" || fail "/config/cameras = ${CAMS} (expected 200)"
fi

# ── 4c2. built-in DB backup: boot catch-up dump landed ───────────────────────
# The api runs a nightly pg_dump itself (services/api/src/db_backup.rs) and
# takes an immediate catch-up dump on boot when none exists — so a fresh
# install must produce a daily/*.sql.gz within moments of becoming healthy.
info "built-in DB backup (boot catch-up dump)"
DUMP_OK=0
for i in $(seq 1 15); do
  if ls "${BACKUP_DIR}"/daily/*.sql.gz >/dev/null 2>&1; then DUMP_OK=1; break; fi
  sleep 2
done
if [ "${DUMP_OK}" = "1" ]; then
  pass "boot catch-up dump landed: $(ls "${BACKUP_DIR}"/daily/*.sql.gz | head -1)"
else
  fail "no *.sql.gz under ${BACKUP_DIR}/daily after 30s (built-in backup job broken?)"
  "${COMPOSE[@]}" logs api 2>&1 | grep -i backup | tail -5 >&2 || true
fi

# ── 4d. no panic / FATAL in the logs ─────────────────────────────────────────
info "no panic/FATAL in api + recorder logs"
BAD="$("${COMPOSE[@]}" logs api recorder 2>&1 | grep -icE 'panicked|thread .main. panicked|FATAL|level.:.ERROR' || true)"
if [ "${BAD}" = "0" ]; then pass "no panic/FATAL/ERROR log lines"; else
  fail "${BAD} panic/FATAL/ERROR log line(s):"
  "${COMPOSE[@]}" logs api recorder 2>&1 | grep -iE 'panicked|FATAL|level.:.ERROR' | head -8 >&2
fi

# ── 4e. recorder live segment index: in-flight + fresh UTC timestamps ────────
# Adds a camera pointing at the synthetic RTSP source (the `testsrc` service in
# docker-compose.smoke.yml), records briefly, and asserts the recorder indexes
# segments IN-FLIGHT (at each ffmpeg boundary line — not via the 15-min
# reconcile) with fresh UTC timestamps:
#   1. segment rows appear at all (boundary indexing works);
#   2. now() - max(start_ts) is small (catches the localtime-strftime class of
#      bug — regression 2026-07-03: TZ on the recorder container made ffmpeg
#      stamp filenames in local time, every row landed hours in the past and
#      the live index froze while footage silently aged out early);
#   3. max(start_ts) ADVANCES across a 10s window (proves in-flight indexing,
#      since the reconcile pass only runs every 15 min).
info "recorder live segment index (in-flight, fresh UTC timestamps)"
seg_probe() { # -> "count lag_seconds max_ts"
  "${COMPOSE[@]}" exec -T postgres psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
    "select count(*) || ' ' || coalesce(round(extract(epoch from (now()-max(start_ts))))::text,'-1') || ' ' || coalesce(max(start_ts)::text,'none') from segments" \
    2>/dev/null | tr -d '\r'
}
if [ -n "${TOKEN}" ]; then
  CREATE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API_URL}/config/cameras" \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -d '{"name":"smoke testsrc","go2rtc_name":"smoketestsrc","main_url":"rtsp://testsrc:8554/cam"}' 2>/dev/null || true)"
  if [ "${CREATE}" = "201" ]; then pass "camera created (direct rtsp://testsrc:8554/cam)"; else
    fail "camera create = ${CREATE} (expected 201)"; fi

  # Worker pickup (CONFIG_POLL_SECONDS=30) + ffmpeg start + 2 boundaries ≈ 45-60s.
  SEG_COUNT=0; SEG_LAG=-1; SEG_MAX=none
  for i in $(seq 1 60); do
    read -r SEG_COUNT SEG_LAG SEG_MAX <<<"$(seg_probe)"
    if [ "${SEG_COUNT:-0}" -ge 2 ] 2>/dev/null; then break; fi
    sleep 3
  done
  if [ "${SEG_COUNT:-0}" -ge 2 ] 2>/dev/null; then
    pass "segment rows appeared (count=${SEG_COUNT})"
  else
    fail "no segment rows after 180s of recording (count='${SEG_COUNT}')"
    "${COMPOSE[@]}" logs --tail 20 recorder >&2 || true
  fi

  # Freshness: a healthy 4s-segment pipeline keeps max(start_ts) within ~10s of
  # now(); hours = the TZ bug, minutes = indexing only via reconcile.
  if [ "${SEG_LAG:-999}" -ge 0 ] 2>/dev/null && [ "${SEG_LAG}" -lt 30 ] 2>/dev/null; then
    pass "max(start_ts) is fresh (lag ${SEG_LAG}s < 30s; UTC-correct)"
  else
    fail "max(start_ts) lag = ${SEG_LAG}s (expected < 30s — frozen index or non-UTC timestamps; max=${SEG_MAX})"
  fi

  # In-flight: max(start_ts) must ADVANCE across 10s (reconcile is 15-min).
  SEG_MAX_BEFORE="${SEG_MAX}"
  sleep 10
  read -r SEG_COUNT SEG_LAG SEG_MAX <<<"$(seg_probe)"
  if [ "${SEG_MAX}" != "none" ] && [ "${SEG_MAX}" != "${SEG_MAX_BEFORE}" ]; then
    pass "max(start_ts) advanced within 10s (in-flight indexing live)"
  else
    fail "max(start_ts) did not advance within 10s (still '${SEG_MAX}') — in-flight indexing frozen"
  fi
else
  fail "skipping recorder live-index check (no admin token)"
fi

# ── verdict ──────────────────────────────────────────────────────────────────
info "result"
if [ "${FAILED}" = "0" ]; then
  printf '\033[32mFRESH-INSTALL SMOKE: PASS\033[0m — a from-scratch install boots healthy and first-run works.\n'
  exit 0
else
  printf '\033[31mFRESH-INSTALL SMOKE: FAIL\033[0m — see the FAIL lines above.\n' >&2
  exit 1
fi
