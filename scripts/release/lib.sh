#!/usr/bin/env bash
# Shared helpers + host/path config for the Crumb release scripts.
#
# This is the maintainer's multi-host release orchestration, published as a
# reference. The three hosts are SSH aliases you define in ~/.ssh/config for
# YOUR environment; the defaults below are placeholders — override them for your
# setup via the CRUMB_* env vars (or edit them):
#   CRUMB_BUILD_HOST — Linux host for the Rust gate + Android + Linux-desktop builds
#   CRUMB_PROD_HOST  — production backend host (docker compose at $PROD_APP)
#   CRUMB_MAC_HOST   — macOS host for iOS/macOS builds
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

DEV1="${CRUMB_BUILD_HOST:-build-host}"  # Rust gate + Android + Linux-desktop build host
PROD="${CRUMB_PROD_HOST:-prod-host}"    # production backend (docker compose at $PROD_APP)
MAC="${CRUMB_MAC_HOST:-mac-host}"       # iOS/macOS build host

GATE_DIR="crumb-gate"                  # ~/crumb-gate on the build host (Rust workspace copy)
ANDROID_DIR="projects/crumb-android"   # ~/projects/crumb-android on the build host
DESKTOP_DIR="projects/crumb-desktop"   # ~/projects/crumb-desktop on the build host (Linux)
APK_SERVE="apk-serve"                  # ~/apk-serve on the build host (served on :8088)
PROD_APP="${CRUMB_PROD_APP:-/opt/crumb/app}"  # source copy on the prod host (docker build ctx)
MAC_REPO="${CRUMB_MAC_REPO:-/path/to/repo/on/mac}"  # repo mount/checkout on the Mac host

# Windows desktop: libmpv-2.dll is loaded at runtime from next to the exe.
# Set CRUMB_LIBMPV_DLL to the path of your libmpv-2.dll.
LIBMPV_DLL="${CRUMB_LIBMPV_DLL:-}"

# Files that make up the Rust backend build (workspace + migrations + embedded VERSION).
BACKEND_PATHS=(services db Cargo.toml Cargo.lock VERSION)

c_reset=$'\033[0m'; c_cyan=$'\033[1;36m'; c_grn=$'\033[1;32m'; c_red=$'\033[1;31m'; c_yel=$'\033[1;33m'
log(){  printf '%s\n== %s ==%s\n' "$c_cyan" "$*" "$c_reset"; }
ok(){   printf '%s✓ %s%s\n' "$c_grn" "$*" "$c_reset"; }
warn(){ printf '%s! %s%s\n' "$c_yel" "$*" "$c_reset"; }
die(){  printf '%s✗ %s%s\n' "$c_red" "$*" "$c_reset" >&2; exit 1; }

# Tar a set of repo paths to a remote directory. --no-same-owner avoids a
# UID-mismatch extract trap on some hosts; the dir is created if missing.
sync_to(){  # sync_to <host> <remote_dir> <repo_path...>
  local host="$1" rdir="$2"; shift 2
  tar -C "$REPO_ROOT" -cf - "$@" \
    | ssh "$host" "mkdir -p '$rdir' && tar -C '$rdir' --no-same-owner -xf -"
}
