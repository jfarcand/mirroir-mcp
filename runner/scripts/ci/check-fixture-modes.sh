#!/usr/bin/env bash
# ABOUTME: Fails when a sample fixture script under runner/samples/*/fixtures/ that starts
# ABOUTME: with a shebang is not mode 100755 in the git index — CI execs some with no shell.
#
# A fixture the runner execs directly (a scene decider, for one) loses its
# executable bit silently on a copy or a fresh `git add`, and CI then fails
# deep into the macOS job. This catches it in seconds, before the push.
#
# Runnable from anywhere inside the repo.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
FIXTURES='runner/samples/*/fixtures/*'

bad=0
# `git ls-files -s` prints "<mode> <object> <stage>\t<path>".
while IFS=$'\t' read -r meta path; do
    read -r mode object _stage <<< "$meta"
    [ "$(git -C "$REPO_ROOT" cat-file -p "$object" | head -c 2)" = '#!' ] || continue
    if [ "$mode" != 100755 ]; then
        echo "  $path has a shebang but is mode $mode in the index"
        echo "    fix: git update-index --chmod=+x $path"
        bad=1
    fi
done < <(git -C "$REPO_ROOT" ls-files -s -- "$FIXTURES")

if [ "$bad" -ne 0 ]; then
    echo "check-fixture-modes: a fixture with a shebang is not executable (git mode 100755)"
    exit 1
fi
echo "check-fixture-modes: every fixture with a shebang is mode 100755"
