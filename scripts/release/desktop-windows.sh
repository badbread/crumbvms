#!/usr/bin/env bash
echo "RETIRED: the desktop release is the Flutter client, built by .github/workflows/windows-release-flutter.yml" >&2
exit 1

# Build the Windows desktop client (Tauri) NATIVELY on this workstation.
#
# This is the one target that builds locally, not over SSH: the desktop crate is
# Windows-native (Win32 child-window compositing) and is its own cargo workspace.
# A debug `cargo build` produces a runnable exe; libmpv-2.dll must sit next to it
# (loaded at runtime — without it the live/playback panes render black).
#
# IMPORTANT — RUN_DIR: the app is RUN from a LOCAL build/run directory (faster,
# and lets the repo live on a network share while the build stays local). We
# SYNC the repo's desktop source into that copy and build THERE — building the
# in-repo tree directly would leave the launched copy stale. Set RUN_DIR to your
# local build/run directory via CRUMB_DESKTOP_RUN_DIR; the in-repo tree stays
# the source of truth.
#
# A signed/bundled installer (cargo tauri build) is a separate distribution task:
# the bundle config doesn't yet ship libmpv-2.dll as a resource. See README.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN_DIR="${CRUMB_DESKTOP_RUN_DIR:-$HOME/crumb-desktop-build}"
SRCD="$REPO_ROOT/apps/desktop"

# A running instance locks the exe so cargo can't overwrite it. A release replaces
# the client anyway, so close it first (warn). --no-kill turns this into an error.
KILL=1
for a in "$@"; do
  case "$a" in
    --no-kill) KILL=0 ;;
    *) die "desktop-windows.sh: unknown arg '$a'" ;;
  esac
done

EXE_NAME="crumb-desktop.exe"
if tasklist //FI "IMAGENAME eq $EXE_NAME" 2>/dev/null | grep -qi "$EXE_NAME"; then
  if [ "$KILL" = 1 ]; then
    warn "$EXE_NAME is running — closing it so the build can replace it"
    taskkill //IM "$EXE_NAME" //F >/dev/null 2>&1 || true
    sleep 1
  else
    die "$EXE_NAME is running — close the Crumb desktop first (or drop --no-kill)"
  fi
fi

# Sync the in-repo desktop source into the local RUN_DIR (mirror src + src-tauri
# sources; PRESERVE the build cache under src-tauri/target for incremental builds).
log "Sync desktop source → $RUN_DIR"
mkdir -p "$RUN_DIR/src-tauri"
rm -rf "$RUN_DIR/src"; cp -r "$SRCD/src" "$RUN_DIR/src"
rm -rf "$RUN_DIR/src-tauri/src"; cp -r "$SRCD/src-tauri/src" "$RUN_DIR/src-tauri/src"
for f in Cargo.toml Cargo.lock tauri.conf.json build.rs; do
  [ -f "$SRCD/src-tauri/$f" ] && cp -f "$SRCD/src-tauri/$f" "$RUN_DIR/src-tauri/$f"
done
[ -d "$SRCD/src-tauri/capabilities" ] && cp -rf "$SRCD/src-tauri/capabilities" "$RUN_DIR/src-tauri/"
[ -d "$SRCD/src-tauri/icons" ] && cp -rf "$SRCD/src-tauri/icons" "$RUN_DIR/src-tauri/"

SRC="$RUN_DIR/src-tauri"
log "Desktop (Windows) build — cargo build in $SRC"
( cd "$SRC" && cargo build ) || die "windows desktop build failed"

EXE="$(ls "$SRC"/target/debug/*.exe 2>/dev/null | head -1)"
[ -n "$EXE" ] && [ -f "$EXE" ] || die "built exe not found under $SRC/target/debug"

if [ -f "$LIBMPV_DLL" ]; then
  cp -f "$LIBMPV_DLL" "$(dirname "$EXE")/libmpv-2.dll"
  ok "placed libmpv-2.dll next to the exe"
else
  warn "libmpv-2.dll not found at $LIBMPV_DLL — live/playback panes stay black until it's next to the exe (set CRUMB_LIBMPV_DLL)"
fi

ok "Desktop (Windows) built → $EXE"
