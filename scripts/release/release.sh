#!/usr/bin/env bash
# Crumb release orchestrator — fan a release out to the chosen build hosts.
#
# Targets:  backend  android  ios  desktop-windows  desktop-linux
#           desktop (= both desktops)   all (= everything)
# Order is fixed: backend (gated, then deployed) runs first, then the clients.
# Flags after targets pass through to backend.sh (--api-only/--gate-only/--no-gate).
#
# Examples:
#   bash scripts/release/release.sh all
#   bash scripts/release/release.sh backend android
#   bash scripts/release/release.sh desktop
#   bash scripts/release/release.sh backend --api-only
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HERE="$(dirname "${BASH_SOURCE[0]}")"

USAGE="usage: release.sh <backend|android|ios|desktop-windows|desktop-linux|desktop|all> [target...] [--api-only|--gate-only|--no-gate]"
[ $# -gt 0 ] || die "$USAGE"

ALL=(backend android ios desktop-linux desktop-windows)
TARGETS=(); FLAGS=()
for a in "$@"; do
  case "$a" in
    --*) FLAGS+=("$a") ;;
    all) TARGETS=("${ALL[@]}") ;;
    desktop) TARGETS+=(desktop-linux desktop-windows) ;;
    backend|android|ios|desktop-windows|desktop-linux) TARGETS+=("$a") ;;
    *) die "unknown target '$a'. $USAGE" ;;
  esac
done
[ ${#TARGETS[@]} -gt 0 ] || die "no targets given"

declare -A RESULT
have(){ local x; for x in "${TARGETS[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
run(){ local name="$1"; shift; if "$@"; then RESULT[$name]=OK; else RESULT[$name]=FAIL; fi; }

# Fixed order: backend first so a freshly-deployed API is live before clients ship.
have backend         && run backend         bash "$HERE/backend.sh" "${FLAGS[@]}"
have android         && run android         bash "$HERE/android.sh"
have ios             && run ios             bash "$HERE/ios.sh"
have desktop-linux   && run desktop-linux   bash "$HERE/desktop-linux.sh"
have desktop-windows && run desktop-windows bash "$HERE/desktop-windows.sh"

log "Release summary"
fail=0
for t in backend android ios desktop-linux desktop-windows; do
  [ -n "${RESULT[$t]:-}" ] || continue
  printf '  %-9s %s\n' "$t" "${RESULT[$t]}"
  [ "${RESULT[$t]}" = OK ] || fail=1
done
[ "$fail" = 0 ] || die "one or more targets failed"
ok "release complete"
