#!/usr/bin/env bash
# Crumb release changelog — a flat bulleted list of every merged PR in a range.
#
# The repo squash-merges, so every merged PR is exactly one commit whose subject
# ends in "(#N)". This prints one bullet per such commit, which is the
# "every single change" list to drop into the release notes / CHANGELOG.
#
# Usage:
#   scripts/release/pr-changelog.sh                 # since the most recent tag → HEAD
#   scripts/release/pr-changelog.sh v0.1.0          # since v0.1.0 → HEAD
#   scripts/release/pr-changelog.sh v0.1.0 v0.2.0   # exactly the v0.1.0..v0.2.0 range
#
# Notes:
# - Runs a `git fetch --tags` first so tags/main are current (skippable with
#   CRUMB_NO_FETCH=1, e.g. offline).
# - Scoping is git-range based ON PURPOSE. `gh pr list --search "merged:>DATE"`
#   is date-granular and wrongly sweeps in same-day PRs merged *before* the tag;
#   a commit range is exact.
set -euo pipefail

REMOTE="${CRUMB_REMOTE:-origin}"
BRANCH="${CRUMB_BRANCH:-main}"

if [[ "${CRUMB_NO_FETCH:-}" != "1" ]]; then
  git fetch --quiet --tags "${REMOTE}" "${BRANCH}"
fi

head_ref="${REMOTE}/${BRANCH}"

case "$#" in
  0) from="$(git describe --tags --abbrev=0 "${head_ref}")"; to="${head_ref}" ;;
  1) from="$1"; to="${head_ref}" ;;
  2) from="$1"; to="$2" ;;
  *) echo "usage: $0 [FROM_TAG [TO_REF]]" >&2; exit 2 ;;
esac

# One bullet per squash-merged PR (subject ends in "(#N)"), newest first.
count="$(git log "${from}..${to}" --format='%s' | grep -cE '\(#[0-9]+\)$' || true)"
git log "${from}..${to}" --format='- %s' | grep -aE '\(#[0-9]+\)$' || true

echo >&2
echo "${count} merged PR(s) in ${from}..${to}" >&2
