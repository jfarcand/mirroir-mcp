#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: SessionStart hook — reports what a session that died left behind, across every worktree
# ABOUTME: The only cover for a kill -9: a dead session fires no exit hook and cannot report on itself
#
# Wire it in .claude/settings.json alongside the other SessionStart hooks.
#
# A clean exit is caught by carnet's SessionEnd release. It does not fire when the process is killed, the terminal is closed, or the context runs out —
# and that is the case that has been costing whole nights. Nothing inside the dead session can
# find it, so the next session in the repo looks for it instead.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bilan="$here/../bilan.sh"
[ -f "$bilan" ] || exit 0

# Record which files were ALREADY dirty when this session opened. Several sessions share the
# main checkout, so a file a peer is mid-edit on caps every other session at 7 — and those
# sessions are right to refuse to touch it, which used to mean they could never reach 10 no
# matter what they did. A path dirty before this session existed is definitionally not this
# session's work, and that IS machine-decidable. Anything that goes dirty later still caps.
bash "$bilan" baseline >/dev/null 2>&1 || true

out=$(bash "$bilan" sweep 2>/dev/null) || exit 0
printf '%s\n' "$out" | grep -q '✅ nothing left behind' && exit 0
printf '%s\n' "$out"
exit 0
