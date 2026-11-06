#!/usr/bin/env bash
# ABOUTME: CI gate for a path-scoped workflow: always runs on tags and non-push events, on main unless
# ABOUTME: the push changed only documentation, and on a branch only when a file matches the given globs.
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
# A documentation-only push to main skips these lanes because no lane reads
# those files, and each run queues for up to an hour of macOS runner time.
# Any other file on main runs them, whether or not it matches a pattern.
#
# Reads GITHUB_EVENT_NAME, GITHUB_REF, GITHUB_SHA and PUSH_BEFORE
# (github.event.before); writes `run=true|false` to GITHUB_OUTPUT.

set -euo pipefail

ZERO_OID="0000000000000000000000000000000000000000"

# The files no gated lane reads. website/ has its own deploy workflow.
DOC_ONLY_PATHS=('docs/*' 'website/*' 'README.md' 'CONTRIBUTING.md' 'CLA.md' 'llms.txt')

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
    refs/tags/*) decide true "$GITHUB_REF always runs" ;;
esac

before_is_known() {
    [ "$before" != "$ZERO_OID" ] && git cat-file -e "${before}^{commit}" 2>/dev/null
}

is_doc_only_path() {
    local pattern
    for pattern in "${DOC_ONLY_PATHS[@]}"; do
        # shellcheck disable=SC2053  # the right side is a glob on purpose
        [[ "$1" == $pattern ]] && return 0
    done
    return 1
}

before="${PUSH_BEFORE:-$ZERO_OID}"

if [ "$GITHUB_REF" = refs/heads/main ]; then
    before_is_known || decide true "main push with no known previous commit"
    changed="$(git diff --name-only --no-renames "$before" "$GITHUB_SHA")"
    [ -n "$changed" ] || decide true "main push with no file changes"
    while IFS= read -r file; do
        is_doc_only_path "$file" || decide true "main push changed $file"
    done <<< "$changed"
    decide false "main push changed only documentation"
fi

# The push's own range when its old tip is known; a new branch (zero
# before) or a force-push whose old tip is gone diffs from where the
# branch left main instead.
if before_is_known; then
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
