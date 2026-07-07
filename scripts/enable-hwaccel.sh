#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Crumb — enable hardware-accelerated motion decode with one command
#
# Docker containers cannot grant themselves devices, so hardware decode always
# needs a host-side compose change (same as Frigate). This script automates it:
#
#   1. Detects what the HOST actually has:
#        * VAAPI  — /dev/dri/renderD* render nodes (Intel/AMD iGPU)
#        * NVDEC  — a working NVIDIA driver (nvidia-smi) + nvidia-container-toolkit
#   2. Writes the matching stanza into docker-compose.override.yml (auto-loaded
#      by every plain `docker compose up -d` — no -f flags to remember).
#   3. Restarts the recorder so the device is mapped in.
#
# Afterwards, pick the backend in the console (Management → Detection & Clips →
# Motion decoding) — the panel shows the requested vs ACTIVE backend per camera,
# so you can see the switch take effect. The admin-set backend (DB) wins over
# the env default this script writes, so the UI stays the source of truth.
#
# Usage:
#   scripts/enable-hwaccel.sh                    # autodetect; picks the only
#                                                # available backend, or asks you
#                                                # to choose when both exist
#   scripts/enable-hwaccel.sh --backend vaapi    # Intel/AMD iGPU (Quick Sync)
#   scripts/enable-hwaccel.sh --backend nvdec    # NVIDIA discrete GPU
#   scripts/enable-hwaccel.sh --device /dev/dri/renderD129   # non-default node
#   scripts/enable-hwaccel.sh --print            # print the stanza, write nothing
#   scripts/enable-hwaccel.sh --no-restart       # write the override, skip the
#                                                # recorder restart
#
# Safe by design: refuses to touch an existing docker-compose.override.yml
# (prints the stanza for you to merge by hand instead). Power note: on a box
# with an iGPU, VAAPI is usually the most power-efficient choice; a discrete
# NVIDIA card's fixed activation power can exceed the decode savings for a
# handful of low-fps sub-streams — measure at the wall if it matters to you.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

OVERRIDE_FILE="${OVERRIDE_FILE:-${REPO_ROOT}/docker-compose.override.yml}"

BACKEND=""
DEVICE=""
PRINT=0
RESTART=1
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND="${2:-}"; shift 2 ;;
    --backend=*) BACKEND="${1#*=}"; shift ;;
    --device) DEVICE="${2:-}"; shift 2 ;;
    --device=*) DEVICE="${1#*=}"; shift ;;
    --print) PRINT=1; shift ;;
    --no-restart) RESTART=0; shift ;;
    -h|--help) grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1 (see --help)" >&2; exit 1 ;;
  esac
done

if [ ! -f "${REPO_ROOT}/docker-compose.yml" ]; then
  echo "error: run from a Crumb checkout (docker-compose.yml not found at ${REPO_ROOT})" >&2
  exit 1
fi

# ── detect ───────────────────────────────────────────────────────────────────
have_vaapi=0
first_node=""
for n in /dev/dri/renderD*; do
  [ -e "$n" ] || continue
  have_vaapi=1
  [ -z "$first_node" ] && first_node="$n"
done

have_nvdec=0
nvdec_note=""
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  have_nvdec=1
  if ! docker info 2>/dev/null | grep -qi nvidia; then
    # Driver works but Docker doesn't list the nvidia runtime — Compose GPU
    # reservations may still work via CDI, but flag it honestly.
    nvdec_note="warning: nvidia-smi works but 'docker info' shows no nvidia runtime — install nvidia-container-toolkit if the recorder fails to see the GPU."
  fi
fi

case "${BACKEND}" in
  "")
    if [ "$have_vaapi" = 1 ] && [ "$have_nvdec" = 1 ]; then
      echo "Both backends are available on this host:"
      echo "  vaapi — iGPU render node(s): $(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')"
      echo "  nvdec — $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
      echo "Re-run with an explicit choice: scripts/enable-hwaccel.sh --backend vaapi|nvdec" >&2
      exit 1
    elif [ "$have_vaapi" = 1 ]; then BACKEND=vaapi
    elif [ "$have_nvdec" = 1 ]; then BACKEND=nvdec
    else
      echo "No hardware decode support detected on this host:" >&2
      echo "  * no /dev/dri/renderD* node (Intel/AMD iGPU)" >&2
      echo "  * no working nvidia-smi (NVIDIA driver)" >&2
      echo "CPU decode (the default) keeps working — nothing to do." >&2
      exit 1
    fi ;;
  vaapi|nvdec) ;;
  cuda) BACKEND=nvdec ;;
  *) echo "error: --backend must be vaapi or nvdec, got '${BACKEND}'" >&2; exit 1 ;;
esac

# ── build the stanza ─────────────────────────────────────────────────────────
if [ "${BACKEND}" = vaapi ]; then
  if [ "$have_vaapi" = 0 ] && [ -z "${DEVICE}" ]; then
    echo "error: --backend vaapi but no /dev/dri/renderD* node exists on this host" >&2
    exit 1
  fi
  DEVICE="${DEVICE:-$first_node}"
  if [ ! -e "${DEVICE}" ]; then
    echo "error: render node '${DEVICE}' does not exist" >&2
    exit 1
  fi
  # GID the container's uid-1001 user needs to open the node: the host 'render'
  # group when it exists, else the node's owning group.
  RENDER_GID="$(getent group render 2>/dev/null | cut -d: -f3 || true)"
  [ -z "${RENDER_GID}" ] && RENDER_GID="$(stat -c %g "${DEVICE}")"
  STANZA="$(cat <<EOF
# Generated by scripts/enable-hwaccel.sh ($(date -u +%Y-%m-%dT%H:%M:%SZ)) — VAAPI
# motion decode. Mirrors docker-compose.vaapi.example.yml. Auto-loaded by every
# plain 'docker compose up -d'. Delete this file to revert to CPU decode.
# Values are LITERAL (detected on this host) — unlike the example overlay's
# \${VAR:-default} pattern, a stale MOTION_HWACCEL in .env can't silently
# defeat what this script just configured. Edit or delete this file to change.
services:
  recorder:
    environment:
      MOTION_HWACCEL: vaapi
      MOTION_VAAPI_DEVICE: ${DEVICE}
    devices:
      - ${DEVICE}:${DEVICE}
    group_add:
      - "${RENDER_GID}"
EOF
)"
else
  if [ "$have_nvdec" = 0 ]; then
    echo "error: --backend nvdec but nvidia-smi is missing or not working on this host" >&2
    exit 1
  fi
  [ -n "${nvdec_note}" ] && echo "${nvdec_note}" >&2
  STANZA="$(cat <<'EOF'
# Generated by scripts/enable-hwaccel.sh — NVDEC motion decode. Mirrors
# docker-compose.gpu.example.yml. Auto-loaded by every plain
# 'docker compose up -d'. Delete this file to revert to CPU decode.
# Values are LITERAL — a stale MOTION_HWACCEL in .env can't silently defeat
# what this script just configured. Edit or delete this file to change.
services:
  recorder:
    environment:
      MOTION_HWACCEL: cuda
      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: video,compute,utility
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu, video]
EOF
)"
fi

if [ "${PRINT}" = 1 ]; then
  echo "${STANZA}"
  exit 0
fi

# ── write (never clobber) ────────────────────────────────────────────────────
if [ -e "${OVERRIDE_FILE}" ]; then
  echo "error: ${OVERRIDE_FILE} already exists — not touching it." >&2
  echo "Merge this stanza into it yourself (or move your override aside and re-run):" >&2
  echo >&2
  echo "${STANZA}" >&2
  exit 1
fi
printf '%s\n' "${STANZA}" > "${OVERRIDE_FILE}"
echo "wrote ${OVERRIDE_FILE} (backend: ${BACKEND}$( [ "${BACKEND}" = vaapi ] && echo ", device: ${DEVICE}, render gid: ${RENDER_GID}" ))"

# ── restart the recorder with the device mapped ──────────────────────────────
if [ "${RESTART}" = 1 ]; then
  echo "restarting the recorder with the new device mapping…"
  docker compose up -d recorder
  echo
  echo "Done. Verify in the console: Management → Detection & Clips → Motion"
  echo "decoding — the status strip shows the device the recorder can now see,"
  echo "and each camera shows its requested vs ACTIVE backend. (Or:"
  echo "GET /config/decode-status as admin.)"
else
  echo "skipped restart (--no-restart). Apply with: docker compose up -d recorder"
fi
