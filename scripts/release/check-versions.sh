#!/usr/bin/env bash
#
# Release version guard.
#
# Verifies that EVERY version surface in the repo matches the release tag, so a
# `vX.Y.Z` tag can never ship artifacts whose baked-in version disagrees with the
# tag. This is the guard against the 0.1.x-era "the app versions did not match the
# tag" class of mistake. The three *-release.yml workflows run this as a gating
# job and their build jobs `needs:` it, so a mismatch blocks the release before a
# single artifact is built.
#
# Usage:
#   scripts/release/check-versions.sh v0.2.0     # explicit tag
#   scripts/release/check-versions.sh            # reads $GITHUB_REF_NAME (CI)
#
# On a ref that is not a vX.Y.Z tag (e.g. a workflow_dispatch run from a branch)
# it is a no-op success, so the manual re-ship paths keep working.
set -euo pipefail

tag="${1:-${GITHUB_REF_NAME:-}}"
want="${tag#v}"

if [[ ! "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ref '${tag:-<none>}' is not a vX.Y.Z release tag; nothing to check."
  exit 0
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

check() { # label  actual  expected
  if [[ "$2" == "$3" ]]; then
    printf 'ok   %-30s %s\n' "$1" "$2"
  else
    printf 'FAIL %-30s got %s, expected %s\n' "$1" "${2:-<empty>}" "$3"
    fail=1
  fi
}

check "VERSION" \
  "$(tr -d ' \t\r\n' < "$root/VERSION")" "$want"

for c in api common recorder; do
  check "services/$c Cargo.toml" \
    "$(grep -m1 '^version' "$root/services/$c/Cargo.toml" | sed -E 's/.*"([^"]+)".*/\1/')" "$want"
done

check "android VERSION_NAME" \
  "$(grep -m1 '^VERSION_NAME=' "$root/apps/android/version.properties" | cut -d= -f2 | tr -d ' \r')" "$want"

check "ios MARKETING_VERSION" \
  "$(grep -m1 'MARKETING_VERSION' "$root/apps/ios/project.yml" | sed -E 's/.*MARKETING_VERSION:[[:space:]]*"?([0-9]+\.[0-9]+\.[0-9]+)"?.*/\1/')" "$want"

check "flutter pubspec" \
  "$(grep -m1 '^version:' "$root/apps/desktop-flutter/pubspec.yaml" | sed -E 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')" "$want"

echo
if [[ "$fail" -ne 0 ]]; then
  echo "Release version guard FAILED for tag $tag."
  echo "Bump every surface listed above to $want in the SAME commit you tag,"
  echo "then re-tag. See apps/android/version.properties for the per-surface steps."
  exit 1
fi
echo "Release version guard passed: all surfaces at $want."
