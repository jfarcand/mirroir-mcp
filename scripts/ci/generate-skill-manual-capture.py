#!/usr/bin/env python3
# ABOUTME: Drives generate_skill start/capture/finish on FakeMirroring's Clock over stdio JSON-RPC.
# ABOUTME: Taps "Add Alarm" at its OCR coordinates, captures it, and finishes with emit=true.

"""Manual-capture emit check.

The explore lane emits a scenario from an autonomous walk; this one emits it
from the agent-driven path a client takes: `start` on Clock, a `tap` at the
coordinates `describe_screen` reports for "Add Alarm", a `capture` naming the
label the tap arrived via, then `finish` with `emit: true` into a scratch
consumer repo. Every request waits for its reply before the next is sent,
because the tap coordinates come from the describe reply.

Usage: generate-skill-manual-capture.py <mirroir-mcp-binary> <consumer-dir> <server-log>
"""

import json
import re
import subprocess
import sys

APP_NAME = "Clock"
TAP_LABEL = "Add Alarm"
# Labels the Add Alarm sheet carries and the Alarms list does not: the tap
# landed only when the describe after it shows them.
SHEET_LABELS = ("Cancel", "Save")
SERVER_EXIT_TIMEOUT_S = 30
EMIT_MARKER = "Emitted .mirroir/ iOS leg"


class Server:
    """A mirroir-mcp stdio server answering one request at a time."""

    def __init__(self, binary, log):
        self.proc = subprocess.Popen(
            [binary, "--dangerously-skip-permissions"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
        self.next_id = 1

    def request(self, method, params):
        rid = self.next_id
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()
        for line in self.proc.stdout:
            if not line.strip():
                continue
            reply = json.loads(line)
            if reply.get("id") == rid:
                return reply
        raise SystemExit(f"{method}: server closed stdout before replying")

    def call(self, tool, arguments):
        reply = self.request("tools/call", {"name": tool, "arguments": arguments})
        assert "result" in reply, f"{tool}: no result: {reply}"
        text = "\n".join(c.get("text", "") for c in reply["result"]["content"])
        print(f"--- {tool} {json.dumps(arguments)} ---\n{text}")
        assert not reply["result"].get("isError"), f"{tool} returned isError"
        return text

    def close(self):
        self.proc.stdin.close()
        code = self.proc.wait(timeout=SERVER_EXIT_TIMEOUT_S)
        assert code == 0, f"mirroir-mcp exited {code}"


def coordinates(describe_text, label):
    match = re.search(rf'^- "{re.escape(label)}" at \((-?\d+), (-?\d+)\)$', describe_text, re.M)
    assert match, f'describe_screen reported no "{label}" element'
    return int(match.group(1)), int(match.group(2))


def main():
    binary, consumer, server_log = sys.argv[1:4]
    with open(server_log, "w", encoding="utf-8") as log:
        server = Server(binary, log)
        init = server.request("initialize", {})
        assert "result" in init, f"initialize: no result: {init}"
        # The explore lane leaves Clock running wherever its walk stopped, and
        # a launch of a running app resumes there: force-quit it so start
        # opens Clock cold on the Alarms list.
        server.call("reset_app", {"name": APP_NAME})
        server.call("press_home", {})
        server.call("generate_skill", {"action": "start", "app_name": APP_NAME})
        x, y = coordinates(server.call("describe_screen", {"omit_screenshot": True}), TAP_LABEL)
        server.call("tap", {"x": x, "y": y})
        # describe_screen settles on the post-tap frame, so the capture below
        # reads the sheet rather than the list the tap left.
        sheet = server.call("describe_screen", {"omit_screenshot": True})
        for label in SHEET_LABELS:
            coordinates(sheet, label)
        captured = server.call(
            "generate_skill", {"action": "capture", "action_type": "tap", "arrived_via": TAP_LABEL})
        assert f'arrived via "{TAP_LABEL}"' in captured, "capture did not record the Add Alarm arrival"
        finished = server.call(
            "generate_skill", {"action": "finish", "emit": True, "output_dir": consumer})
        assert EMIT_MARKER in finished, "finish did not emit the .mirroir/ leg"
        server.close()


if __name__ == "__main__":
    main()
