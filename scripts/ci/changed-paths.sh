#!/usr/bin/env bash
# ABOUTME: CI gate for a path-scoped workflow: always runs on main, tags and non-push events,
# ABOUTME: and on a feature-branch push only when a changed file matches one of the given globs.
#
# Usage (from a job that checked out with fetch-depth: 0):
#   scripts/ci/changed-paths.sh 'npm/*' 'mirroir.sh' '.github/workflows/installers.yml'
#
# Patterns are bash globs matched against repo-relative paths, where `*`
# also matches `/` — so 'npm/*' covers everything under npm/.
#
# Why a script and not `on.push.paths`: GitHub applies one paths filter to
# every ref a push trigger covers, so a filter narrow enough for feature
# branches would also skip main and the release tags. The workflow keeps an
# unfiltered push trigger and its macOS jobs wait on this gate instead.
#
# Reads GITHUB_EVENT_NAME, GITHUB_REF, GITHUB_SHA and PUSH_BEFORE
# (github.event.before); writes `run=true|false` to GITHUB_OUTPUT.

set -euo pipefail

ZERO_OID="0000000000000000000000000000000000000000"

decide() {
    echo "run=$1" >> "$GITHUB_OUTPUT"
    echo "changed-paths: run=$1 — $2"
    exit 0
}

[ "$#" -gt 0 ] || { echo "usage: $0 PATTERN..." >&2; exit 2; }

# A manual dispatch is how anyone forces a full run on a branch; a pull
# request or a schedule was already scoped by its own trigger.
[ "$GITHUB_EVENT_NAME" = push ] || decide true "$GITHUB_EVENT_NAME event"

case "$GITHUB_REF" in
    refs/heads/main|refs/tags/*) decide true "$GITHUB_REF always runs" ;;
esac

# The push's own range when its old tip is known; a new branch (zero
# before) or a force-push whose old tip is gone diffs from where the
# branch left main instead.
before="${PUSH_BEFORE:-$ZERO_OID}"
if [ "$before" != "$ZERO_OID" ] && git cat-file -e "${before}^{commit}" 2>/dev/null; then
    base="$before"
elif base="$(git merge-base origin/main "$GITHUB_SHA" 2>/dev/null)"; then
    :
else
    decide true "no base commit to diff against"
fi

changed="$(git diff --name-only --no-renames "$base" "$GITHUB_SHA")"
while IFS= read -r file; do
    [ -n "$file" ] || continue
    for pattern in "$@"; do
        # shellcheck disable=SC2053  # the right side is a glob on purpose
        if [[ "$file" == $pattern ]]; then
            decide true "$file matches '$pattern'"
        fi
    done
done <<< "$changed"

decide false "no file changed in ${base:0:12}..${GITHUB_SHA:0:12} matches $*"
