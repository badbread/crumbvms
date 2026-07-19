#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Crumb — generate a secure .env
#
# Produces a ready-to-run .env with cryptographically strong secrets:
#   * POSTGRES_PASSWORD — openssl rand -hex 32
#   * JWT_SECRET        — openssl rand -hex 32 (>= 32 bytes, required by the API)
#   * SEED_ADMIN_PASSWORD — generated, OR taken from your input (--prompt)
#
# This is the INTERIM secrets posture: strong
# generated secrets in a gitignored .env + a pre-commit hook that blocks
# committing it. A real vault is deferred to Phase 2.
#
# Idempotent: refuses to overwrite an existing .env unless you pass --force.
#
# Usage:
#   scripts/setup-env.sh                # generate all secrets, write .env
#   scripts/setup-env.sh --prompt       # prompt for the admin password instead
#   scripts/setup-env.sh --force        # overwrite an existing .env
#   scripts/setup-env.sh --print        # print the admin password after writing
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

FORCE=0
PROMPT=0
PRINT=0
for arg in "$@"; do
  case "${arg}" in
    --force)  FORCE=1 ;;
    --prompt) PROMPT=1 ;;
    --print)  PRINT=1 ;;
    -h|--help)
      grep -E '^#' "$0" | sed 's/^# \{0,1\}//' ; exit 0 ;;
    *) echo "unknown flag: ${arg}" >&2; exit 1 ;;
  esac
done

log() { printf '[setup-env] %s\n' "$*"; }
die() { printf '[setup-env] ERROR: %s\n' "$*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || die "openssl not found — required to generate secrets"

if [[ -f "${ENV_FILE}" && "${FORCE}" -ne 1 ]]; then
  die "${ENV_FILE} already exists. Refusing to clobber it. Re-run with --force to overwrite (your current secrets will be replaced)."
fi

gen_secret() { openssl rand -hex 32; }
# Admin password: a memorable two-word passphrase (Adjective + Noun) plus a
# three-digit number, e.g. "IcyApples473". It is printed once below so you can
# read it straight into the first-run sign-in, and it avoids characters that
# trip .env parsing. This is a STARTER credential for the LAN-only first login
# (~21 bits of entropy, fine behind the login rate-limiter on a trusted LAN);
# change it in the console, or set your own with --prompt, before exposing the
# console anywhere. The seeded admin also closes the unauthenticated
# /auth/bootstrap window that a blank seed would leave open on first run.
gen_password() {
  local adjectives=(Amber Brave Brisk Calm Clever Cozy Crimson Dapper Eager \
    Fuzzy Gentle Golden Happy Icy Jolly Keen Lively Lucky Mellow Nimble Noble \
    Olive Plucky Quiet Rapid Rosy Rustic Sandy Shiny Silver Snowy Solar Spry \
    Sunny Swift Teal Tidy Vivid Witty Woolly Zesty)
  local nouns=(Acorn Apples Badger Beacon Cactus Cedar Comet Cove Dune Ember \
    Falcon Fern Fjord Grove Harbor Heron Isle Kettle Lantern Lark Maple Meadow \
    Nectar Otter Panda Pebble Pine Quartz Raven Reef Ridge River Robin Sparrow \
    Spruce Thistle Tiger Timber Valley Willow Yarrow)
  printf '%s%s%03d' \
    "${adjectives[RANDOM % ${#adjectives[@]}]}" \
    "${nouns[RANDOM % ${#nouns[@]}]}" \
    "$(( RANDOM % 1000 ))"
}

POSTGRES_PASSWORD="$(gen_secret)"
JWT_SECRET="$(gen_secret)"
# go2rtc Basic-auth / RTSP-auth credentials (P0-GO2RTC lighter lockdown).
# GO2RTC_USER is a fixed, non-secret label (it's Basic-auth's "username" slot,
# not itself sensitive); GO2RTC_PASS is the actual generated secret.
GO2RTC_USER="go2rtc"
GO2RTC_PASS="$(gen_secret)"

if [[ "${PROMPT}" -eq 1 ]]; then
  if [[ ! -t 0 ]]; then die "--prompt requires an interactive terminal"; fi
  printf 'Admin password (leave blank to auto-generate): '
  read -rs ADMIN_INPUT; echo
  if [[ -n "${ADMIN_INPUT}" ]]; then
    printf 'Confirm admin password: '
    read -rs ADMIN_CONFIRM; echo
    [[ "${ADMIN_INPUT}" == "${ADMIN_CONFIRM}" ]] || die "passwords did not match"
    SEED_ADMIN_PASSWORD="${ADMIN_INPUT}"
  else
    SEED_ADMIN_PASSWORD="$(gen_password)"
  fi
else
  SEED_ADMIN_PASSWORD="$(gen_password)"
fi

POSTGRES_USER="${POSTGRES_USER:-crumb}"
POSTGRES_DB="${POSTGRES_DB:-crumb}"
SEED_ADMIN_USERNAME="${SEED_ADMIN_USERNAME:-admin}"

# ── Host facts: timezone + LAN IP ────────────────────────────────────────────
# Detected so a stock .env is correct-by-default without hand-editing. Neither
# is a secret; both are host-local facts written only into the (gitignored) .env.

# TZ drives quiet hours, the nightly DB backup schedule, and all log timestamps.
# Read the host's IANA zone; fall back to UTC (NOT a hardcoded local zone) so a
# non-US operator never silently inherits someone else's clock.
detect_tz() {
  if [[ -r /etc/timezone ]]; then
    local tz; tz="$(tr -d '[:space:]' < /etc/timezone || true)"
    [[ -n "${tz}" ]] && { printf '%s' "${tz}"; return 0; }
  fi
  if [[ -L /etc/localtime ]]; then
    # /etc/localtime → …/zoneinfo/Area/City ; strip everything up to zoneinfo/.
    local target; target="$(readlink /etc/localtime || true)"
    case "${target}" in
      */zoneinfo/*) printf '%s' "${target#*/zoneinfo/}"; return 0 ;;
    esac
  fi
  return 1
}

if TZ_VALUE="$(detect_tz)"; then
  log "detected host timezone: ${TZ_VALUE}"
else
  TZ_VALUE="UTC"
  log "NOTE: could not detect host timezone — defaulting TZ=UTC. Edit TZ in .env to your IANA zone (e.g. Europe/Berlin) so quiet hours, backups, and log timestamps use local time."
fi

# WEBRTC_CANDIDATE is the server's LAN IP that go2rtc advertises to WebRTC/iOS
# live clients as an ICE candidate (docs/IOS-LIVE-VIDEO.md). Detect the primary
# LAN IPv4; if we can't, leave it blank (iOS/WebRTC live simply won't work until
# the operator fills it in) rather than guessing a wrong address.
detect_lan_ip() {
  local ip=""
  # Preferred: the source address the kernel would use to reach off-host.
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1 || true)"
  fi
  # Fallback: first RFC-1918-looking address from hostname -I.
  if [[ -z "${ip}" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)"
  fi
  [[ -n "${ip}" ]] && { printf '%s' "${ip}"; return 0; }
  return 1
}

if LAN_IP="$(detect_lan_ip)"; then
  WEBRTC_CANDIDATE_VALUE="${LAN_IP}:8556"
  log "detected host LAN IP: ${LAN_IP} (WEBRTC_CANDIDATE=${WEBRTC_CANDIDATE_VALUE})"
else
  WEBRTC_CANDIDATE_VALUE=""
  log "NOTE: could not detect a host LAN IP — leaving WEBRTC_CANDIDATE blank. Set it to <server-LAN-ip>:8556 in .env for iOS/WebRTC live view (docs/IOS-LIVE-VIDEO.md)."
fi

# Write atomically: build in a temp file, then move into place.
TMP="$(mktemp "${ENV_FILE}.XXXXXX")"
trap 'rm -f "${TMP}"' EXIT

cat > "${TMP}" <<EOF
# Crumb — generated by scripts/setup-env.sh on $(date '+%Y-%m-%dT%H:%M:%S%z')
# Secrets are strong and gitignored. Do NOT commit this file. Re-run setup-env.sh
# --force to rotate the generated secrets.
#
# After 'docker compose up -d', create your admin in the browser at /admin
# (first-run wizard). No admin password needs to be set here.

# --- Time zone ---
# Detected from this host. Drives quiet hours, the nightly DB backup schedule,
# the offsite-sync cron, and all log timestamps. Change to any IANA zone name
# (e.g. Europe/Berlin); UTC is the fallback when detection fails.
TZ=${TZ_VALUE}

# --- PostgreSQL ---
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
# api + recorder read this directly. For a REMOTE Postgres, change the host here
# and use docker-compose.override.example.yml. Host 'postgres' = the bundled
# compose service name.
DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
# Connection-pool size. Leave commented → code default. Size for load:
# DB_POOL_SIZE=42  # ~2*cameras+10

# --- Streaming bases (FALLBACKS — admin "Server & streaming" settings win) ---
# Crumb's own go2rtc restreamer runs EMBEDDED in the recorder container (the
# recorder spawns + supervises the binary; no separate go2rtc service). Both
# bases: LEAVE BLANK — the per-service compose defaults are correct (api →
# http://recorder:1984 over the internal network; recorder → localhost, go2rtc
# being in-container). go2rtc's REST API has NO host publish (P0-GO2RTC lighter
# lockdown); callers authenticate with GO2RTC_USER/PASS below. RTSP IS still
# LAN-published (18554) for desktop/Android — set the reachable address in the
# admin "Server & streaming" UI (rtsp://<this-host>:18554); the API embeds
# GO2RTC_USER/PASS into that value automatically when it hands out stream URLs,
# so don't put credentials in the admin field yourself.
CRUMB_GO2RTC_API_BASE=
CRUMB_GO2RTC_RTSP_BASE=
# go2rtc Basic-auth / RTSP-auth credentials — generated above. Required:
# docker-compose.yml fails fast if either is unset. Rotating requires
# restarting recorder + api.
GO2RTC_USER=${GO2RTC_USER}
GO2RTC_PASS=${GO2RTC_PASS}
# External (BRING-YOUR-OWN) Frigate's go2rtc — only for cameras served_by='frigate'.
# This is a SEPARATE go2rtc instance with its own credentials (if any);
# GO2RTC_USER/PASS above are never sent to it.
GO2RTC_RTSP_BASE=
GO2RTC_API_BASE=

# --- WebRTC live (iOS/browser) ---
# Detected LAN IP of THIS host (form <server-LAN-ip>:8556). go2rtc hands this to
# WebRTC/iOS clients as an ICE candidate; without it, LAN clients never complete
# ICE and live silently degrades to ~1fps snapshots (docs/IOS-LIVE-VIDEO.md).
# Blank = detection failed; set it yourself if you use the iOS/WebRTC live path.
WEBRTC_CANDIDATE=${WEBRTC_CANDIDATE_VALUE}

# --- Recording ---
SEGMENT_SECONDS=4

# --- Motion-mode RAM cache (docs/MOTION-RECORDING.md) ---
# Motion-mode cameras buffer in a tmpfs ring buffer and persist to disk only
# on motion (pre-roll + event + post-roll); idle footage never touches disk.
# 512 MiB comfortably covers ~10 cameras at a 30s pre-roll -- see .env.example
# for the full sizing rule of thumb.
MOTION_CACHE_TMPFS_BYTES=536870912
# Shadow mode: record everything as before, but stamp each segment with the
# keep/discard verdict the motion buffer would have made, to validate before
# flipping a camera to Motion mode live. Off by default.
MOTION_RECORDING_SHADOW=0

# --- Storage ---
# ONE broad media root, bind-mounted into both containers. Add a disk by mounting
# it under MEDIA_HOST_PATH and adding the storage path '/data/<subdir>' in the UI.
MEDIA_HOST_PATH=./_data
MEDIA_ROOT=/data
LIVE_STORAGE_PATH=/data/live
ARCHIVE_STORAGE_PATH=/data/archive

# --- GPU / motion decode ---
# 'auto' uses NVDEC when a GPU is present, else CPU. GPU access is opt-in via
# docker-compose.gpu.example.yml. Set 'cuda' to force NVDEC, 'cpu' to force CPU.
MOTION_HWACCEL=auto

# --- API auth ---
JWT_SECRET=${JWT_SECRET}
JWT_EXPIRY_SECONDS=86400

# --- API server ---
API_BIND=0.0.0.0:8080

# --- Export settings ---
# Exports live at a TOP-LEVEL /exports (own named volume), NOT under the API's
# read-only /data mount — a nested mountpoint under a read-only bind can't be
# created on a fresh install and stalls the api container. Must match the compose
# `crumb_exports:/exports` mount + its ${EXPORT_DIR:-/exports} default.
EXPORT_DIR=/exports
EXPORT_TTL_SECONDS=86400

# --- Database backup (built into the api; ON by default -- docs/BACKUP.md) ---
# The api runs a nightly pg_dump (03:15 local) with rotation into this host
# dir. Put it on a DIFFERENT disk than MEDIA_HOST_PATH where practical, and
# keep it writable by uid 1001 (the api's user) -- setup-env.sh prepares the
# default ./backups dir; if you point this elsewhere, chown it yourself.
DB_BACKUP_HOST_PATH=./backups

# --- Off-host backup copy (OPTIONAL; see docs/BACKUP.md "Off-host copies") ---
# The api's built-in backup job (ON by default) writes dumps to a directory on
# THIS host -- a fire/theft/PSU event takes out the segments index, the
# footage, AND the backups together. On-host-only is a fine posture for a
# single-box home install; for real disaster resilience, pick ONE:
#   1. Simplest: point DB_BACKUP_HOST_PATH (above) at a NAS/NFS mount instead
#      of a local dir -- no extra container needed (must stay writable by
#      uid 1001).
#   2. Optional \`backup-offsite\` rclone sidecar (behind the \`offsite\`
#      Compose profile -- absent from a stock \`docker compose up -d\`):
#        docker compose --profile offsite up -d
#      Uncomment + fill in the two vars below, and provide an rclone.conf
#      (generate once with \`rclone config\`).
# BACKUP_OFFSITE_REMOTE=mynas:crumb-backups
# BACKUP_OFFSITE_SCHEDULE=15 5 * * *
# BACKUP_OFFSITE_RCLONE_CONF=./rclone.conf

# --- Alerting (optional) ---
# Generic JSON webhook for recorder-death paging. When set, the API watchdog
# POSTs {content,text} (Discord reads "content", Slack reads "text") when the
# recorder heartbeat goes stale (>60s) and once more on recovery. Empty (default)
# => recorder death is SILENT. Set this for a production install.
# ALERT_WEBHOOK_URL=https://discord.com/api/webhooks/xxxxx/yyyyy
ALERT_WEBHOOK_URL=

# --- Update-available check (optional, issue #7; OFF by default) ---
# When enabled, the api periodically asks github.com for the latest CrumbVMS
# release tag (version number only -- nothing sent) so clients can show an
# "update available" notice. The admin console toggle (Server settings) wins
# over this env once set. false = zero github.com requests, ever.
UPDATE_CHECK_ENABLED=false

# --- Seed (admin bootstrap user) ---
# The default: this .env ships with a generated SEED_ADMIN_PASSWORD (the memorable
# passphrase setup-env.sh printed). The API hashes it at startup (argon2) and
# creates the admin if none exists, so you just open /admin and SIGN IN as this
# user. Seeding the admin also closes the unauthenticated /auth/bootstrap window.
# To use the browser "create admin" wizard instead, blank SEED_ADMIN_PASSWORD
# below (that reopens the bootstrap window until you create the admin). For a
# pre-hashed headless seed, the recorder path reads SEED_ADMIN_PASSWORD_HASH
# (a PHC argon2id string) instead.
SEED_ADMIN_USERNAME=${SEED_ADMIN_USERNAME}
SEED_ADMIN_PASSWORD=${SEED_ADMIN_PASSWORD}
SEED_ADMIN_PASSWORD_HASH=

# Dev-only: seed the hardcoded prototype cameras. KEEP false in real deployments.
SEED_DEFAULT_CAMERAS=false

# --- ONVIF / PTZ (optional, LEGACY fallback) ---
# Per-camera ONVIF creds now live in the admin camera editor. This base64 JSON
# map (keyed by go2rtc_name) is a one-time fallback only. See docker-compose.yml.
ONVIF_CONFIG_B64=

# --- Versioned image deploy (optional; see docs/RELEASE.md) ---
# Images pull from the public default prefix (ghcr.io/badbread/crumbvms) with no
# login. Pin a release with CRUMB_VERSION; only override CRUMB_IMAGE_PREFIX when
# running a fork's own registry (form: ghcr.io/<owner>/<repo>).
# CRUMB_VERSION=v0.1.0
EOF

chmod 600 "${TMP}"
mv "${TMP}" "${ENV_FILE}"
trap - EXIT

# ── Media (recording) directory prep ─────────────────────────────────────────
# The recorder container (uid 1001) writes ALL footage under MEDIA_HOST_PATH
# (default ./_data → /data). If Docker auto-creates this bind-mount dir it ends
# up root:root, the recorder gets EACCES on mkdir /data/live/<camera>, and
# NOTHING is recorded — while live view (go2rtc restream, no disk) still works
# and the setup wizard shows green (the api mounts /data read-only so it can't
# probe writability). Prep it here with the right ownership so a stock install
# actually records. Best-effort: a non-root run without sudo prints exactly what
# to fix, and the recorder now also raises a loud `storage_unwritable` alert.
MEDIA_DIR_HOST="${REPO_ROOT}/_data"
mkdir -p "${MEDIA_DIR_HOST}" 2>/dev/null || true
if [[ -d "${MEDIA_DIR_HOST}" ]]; then
  if chown 1001:1001 "${MEDIA_DIR_HOST}" 2>/dev/null; then
    log "prepared ${MEDIA_DIR_HOST} (owned by uid 1001 — the recorder can write footage)"
  else
    log "NOTE: could not chown ${MEDIA_DIR_HOST} to uid 1001 (not root?)."
    log "      Run: sudo chown -R 1001:1001 ${MEDIA_DIR_HOST}"
    log "      Otherwise the recorder CANNOT write footage and playback stays empty."
  fi
else
  log "NOTE: could not create ${MEDIA_DIR_HOST} — create it and chown 1001:1001 before 'docker compose up', or the recorder records nothing."
fi

# ── DB-backup directory prep ─────────────────────────────────────────────────
# The api container (uid 1001) writes nightly pg_dumps into ./backups (see
# DB_BACKUP_HOST_PATH). If Docker auto-creates the bind-mount dir it ends up
# root-owned and the api can't write (backups get disabled with a warning), so
# create it here with the right ownership while we can. Best-effort: a non-root
# run without sudo still works — the api will say exactly what to fix.
BACKUP_DIR_HOST="${REPO_ROOT}/backups"
mkdir -p "${BACKUP_DIR_HOST}" 2>/dev/null || true
if [[ -d "${BACKUP_DIR_HOST}" ]]; then
  if chown 1001:1001 "${BACKUP_DIR_HOST}" 2>/dev/null; then
    log "prepared ${BACKUP_DIR_HOST} (owned by uid 1001 — the api's backup job can write)"
  else
    log "NOTE: could not chown ${BACKUP_DIR_HOST} to uid 1001 (not root?)."
    log "      Run: sudo chown -R 1001:1001 ${BACKUP_DIR_HOST}"
    log "      Otherwise the api disables its nightly DB backup with a warning."
  fi
else
  log "NOTE: could not create ${BACKUP_DIR_HOST} — create it and chown 1001:1001 before 'docker compose up'."
fi

log "wrote ${ENV_FILE} (mode 600) with freshly generated secrets"
log ""
log "  Console sign-in (write these down, you will not be shown the password again):"
log "    username: ${SEED_ADMIN_USERNAME}"
log "    password: ${SEED_ADMIN_PASSWORD}"
log ""
log "  (also stored as SEED_ADMIN_PASSWORD in ${ENV_FILE}; change it in the console after first login)"
log "NEXT: 'docker compose up -d', then open http://<host>:8080/admin and sign in with the above."
