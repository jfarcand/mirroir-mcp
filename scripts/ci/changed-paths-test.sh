#!/usr/bin/env bash
# ABOUTME: Tests the changed-paths.sh CI gate against a throwaway git repository,
# ABOUTME: one case per decision it can make for main, branches, tags and non-push events.

set -euo pipefail

GATE="$(cd "$(dirname "$0")" && pwd)/changed-paths.sh"
ZERO_OID="0000000000000000000000000000000000000000"
PATTERN='npm/*'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

git init -q -b main
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

commit_change() {
    mkdir -p "$(dirname "$1")"
    echo "$RANDOM" >> "$1"
    git add "$1"
    git commit -qm "change $1"
    git rev-parse HEAD
}

BASE="$(commit_change README.md)"
git update-ref refs/remotes/origin/main "$BASE"
DOCS="$(commit_change docs/guide.md)"
WEBSITE="$(commit_change website/src/index.astro)"
SOURCE="$(commit_change Sources/App.swift)"
NPM="$(commit_change npm/install.js)"

failures=0

# expect NAME EXPECTED EVENT REF SHA BEFORE
expect() {
    local output actual
    output="$WORK/output"
    : > "$output"
    GITHUB_OUTPUT="$output" GITHUB_EVENT_NAME="$3" GITHUB_REF="$4" GITHUB_SHA="$5" PUSH_BEFORE="$6" \
        bash "$GATE" "$PATTERN" > /dev/null
    actual="$(cat "$output")"
    if [ "$actual" = "run=$2" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: expected run=$2, got '$actual'"
        failures=$((failures + 1))
    fi
}

MAIN=refs/heads/main
BRANCH=refs/heads/feature/thing

expect "main, one docs commit, skips"             false push "$MAIN" "$DOCS" "$BASE"
expect "main, docs and website, skips"            false push "$MAIN" "$WEBSITE" "$BASE"
expect "main, code among the docs, runs"          true  push "$MAIN" "$SOURCE" "$BASE"
expect "main, code outside the patterns, runs"    true  push "$MAIN" "$SOURCE" "$WEBSITE"
expect "main, unknown previous commit, runs"      true  push "$MAIN" "$DOCS" "1111111111111111111111111111111111111111"
expect "main, zero previous commit, runs"         true  push "$MAIN" "$DOCS" "$ZERO_OID"
expect "main, no file changes, runs"              true  push "$MAIN" "$DOCS" "$DOCS"
expect "tag on a docs commit, runs"               true  push refs/tags/v1.0.0 "$DOCS" "$BASE"
expect "dispatch on main, runs"                   true  workflow_dispatch "$MAIN" "$DOCS" "$BASE"
expect "pull request, runs"                       true  pull_request "$BRANCH" "$DOCS" "$BASE"
expect "branch, no pattern match, skips"          false push "$BRANCH" "$SOURCE" "$WEBSITE"
expect "branch, pattern match, runs"              true  push "$BRANCH" "$NPM" "$SOURCE"
expect "new branch, diffs from main, runs"        true  push "$BRANCH" "$NPM" "$ZERO_OID"

if [ "$failures" -gt 0 ]; then
    echo "$failures case(s) failed"
    exit 1
fi
echo "all cases passed"
