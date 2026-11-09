#!/bin/bash
# ABOUTME: Runs the unit tests under a throwaway home, so the developer's own ~/.mirroir-mcp and settings cannot change a result.
# ABOUTME: Usage: scripts/unit-tests.sh [xctest|swift-testing|all] [swift test options]; the two runners deadlock in one invocation, so each gets its own.

set -euo pipefail

usage="Usage: scripts/unit-tests.sh [xctest|swift-testing|all] [swift test options]"
runner="all"
case "${1:-}" in
    xctest|swift-testing|all) runner="$1"; shift ;;
    -h|--help) echo "$usage"; exit 0 ;;
    -*|"") ;;
    *) echo "Error: unknown runner '$1'" >&2; echo "$usage" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."

# Build with the real home, so the compiler and package caches stay where they are.
swift build --build-tests

home="$(mktemp -d "${TMPDIR:-/tmp}/mirroir-unit-tests.XXXXXX")"
trap 'rm -rf "$home"' EXIT

# Foundation resolves ~ through this variable, so every ~/.mirroir-mcp lookup
# (settings, permissions, skills, graphs, the debug log) lands in the throwaway
# home. The project-local settings.json is read through the working directory,
# which must stay the package root, so it is replaced by naming a file that
# does not exist.
export CFFIXED_USER_HOME="$home"
export MIRROIR_SETTINGS_FILE="$home/settings.json"

status=0
if [ "$runner" = "xctest" ] || [ "$runner" = "all" ]; then
    swift test --skip-build --skip IntegrationTests --disable-swift-testing "$@" || status=$?
fi
if [ "$runner" = "swift-testing" ] || [ "$runner" = "all" ]; then
    swift test --skip-build --skip IntegrationTests --disable-xctest --no-parallel "$@" || status=$?
fi
exit "$status"
