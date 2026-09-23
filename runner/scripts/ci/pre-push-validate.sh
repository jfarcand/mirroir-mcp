#!/usr/bin/env bash
# ABOUTME: Local pre-push gate for the runner/ Rust workspace — fmt, limitation-register
# ABOUTME: gates, clippy (deny warnings), tests; stamps .git/validation-passed on success.
#
# Tiers, run in order; the first failure aborts:
#   Tier 0  cargo fmt --all -- --check
#   Tier 1  .registre/limitation-gates.sh (deferral prose, markers, ledger,
#           500-line cap, inline clippy allows — see registre.toml at repo root)
#   Tier 2  cargo clippy --all-targets --all-features -- -D warnings
#   Tier 3  cargo test --all-targets
#
# On full success it writes a unix timestamp to <git-dir>/validation-passed.
# The pre-push hook treats that marker as valid for VALIDATION_TTL_SECONDS
# (15 minutes); a stale or missing marker re-requires this script.
#
# Runnable from anywhere inside the repo: it cd's into runner/ itself.

set -euo pipefail

# 15-minute marker TTL — kept in sync with .githooks/pre-push.
VALIDATION_TTL_SECONDS=900

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ci/ -> scripts/ -> runner/
RUNNER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$RUNNER_DIR"

echo "==> Tier 0: cargo fmt --all -- --check"
cargo fmt --all -- --check

echo "==> Tier 1: limitation-register gates (.registre/limitation-gates.sh)"
REPO_ROOT="$(cd "$RUNNER_DIR/.." && pwd)"
if [ ! -x "$REPO_ROOT/.registre/limitation-gates.sh" ]; then
    echo "llm-registre not checked out — run: git submodule update --init"
    exit 1
fi
(cd "$REPO_ROOT" && ./.registre/limitation-gates.sh) || {
    echo ""
    echo "Deferral prose must be implemented or registered — see .registre/README.md"
    echo "and file the gap in jfarcand/mirroir-carnet (tracker in registre.toml)."
    exit 1
}

echo "==> Tier 2: cargo clippy --all-targets --all-features -- -D warnings"
cargo clippy --all-targets --all-features -- -D warnings

echo "==> Tier 3: cargo test --all-targets"
cargo test --all-targets

GIT_DIR="$(git rev-parse --git-dir)"
# Marker line: "<unix-timestamp> <HEAD-commit-sha>". The pre-push hook requires
# both a fresh timestamp AND a SHA matching the commit being pushed, so an
# amended/added commit after validation invalidates the marker.
printf '%s %s\n' "$(date +%s)" "$(git rev-parse HEAD)" > "$GIT_DIR/validation-passed"

echo ""
echo "pre-push-validate: ALL TIERS PASSED"
echo "Stamped $GIT_DIR/validation-passed for commit $(git rev-parse --short HEAD) (valid for $((VALIDATION_TTL_SECONDS / 60)) minutes)."
exit 0
