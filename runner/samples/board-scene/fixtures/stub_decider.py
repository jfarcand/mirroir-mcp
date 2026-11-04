#!/usr/bin/env python3
# ABOUTME: Test-only scene move picker (decider): reads the frame JSON on stdin and prints one fixed action.
# ABOUTME: Its argv names the case, so each board-scene scenario gets a deterministic move without a chess engine.
"""Print a fixed scene action for the board-scene sample in CI.

Usage: stub_decider.py MODE

mirroir-mcp runs the decider once per frame with no shell, writes one JSON
object (run_id, frame, reading, ocr, controls) to its stdin and reads one
action from its stdout. MODE picks the action:

    reach   {"control": "board", "cells": ["a1", "c3"]}  -> GOAL in one frame
    wrong   {"control": "board", "cells": ["a1", "b2"]}  -> DEFAITE
    wait    {"control": "none"}                          -> no touch, budget spent
    broken  no output, exit 1                            -> decider_failed

Modes keep the action out of argv: the decider line is split on whitespace and
quoted into mirroir-mcp's flat step line, where a JSON literal would not survive.
"""

import json
import sys

ACTIONS = {
    "reach": {"control": "board", "cells": ["a1", "c3"], "rationale": "stub"},
    "wrong": {"control": "board", "cells": ["a1", "b2"], "rationale": "stub"},
    "wait": {"control": "none", "rationale": "stub"},
}
BROKEN_MODE = "broken"


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    # Drain the frame so the writer never sees a closed pipe.
    sys.stdin.read()
    if mode == BROKEN_MODE:
        sys.exit(1)
    if mode not in ACTIONS:
        sys.stderr.write(f"stub_decider: unknown mode {mode!r}\n")
        sys.exit(2)
    print(json.dumps(ACTIONS[mode]))


if __name__ == "__main__":
    main()
