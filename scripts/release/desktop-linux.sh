#!/usr/bin/env bash
# Build the Linux desktop client (Tauri, gtk/mpv pane backend) on the build host.
#
# the build host doesn't mount the repo, so the sources are tar'd over; the GTK/WebKitGTK
# build deps are already installed there (same set as the CI desktop-linux job).
# libmpv is loaded at runtime (no build-time dep), so it isn't needed to compile.
# This is a debug `cargo build` (matches CI). A .deb bundle (cargo tauri build) is
# a follow-up — see README.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Sync desktop sources to $DEV1"
tar -C "$REPO_ROOT/apps/desktop" \
    --exclude='src-tauri/target' --exclude='src-tauri/gen' \
    --exclude='node_modules' --exclude='.gradle' \
    -cf - . \
  | ssh "$DEV1" "mkdir -p '$DESKTOP_DIR' && tar -C '$DESKTOP_DIR' --no-same-owner -xf -"

log "cargo build (Linux) on $DEV1"
ssh "$DEV1" "cd ~/$DESKTOP_DIR/src-tauri && cargo build" || die "linux desktop build failed"
ok "Desktop (Linux) built on $DEV1 → ~/$DESKTOP_DIR/src-tauri/target/debug/crumb-desktop"
