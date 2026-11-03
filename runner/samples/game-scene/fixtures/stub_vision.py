# ABOUTME: Test-only stand-in for the scene vision model: an OpenAI-shaped /v1/chat/completions that always names one control.
# ABOUTME: A paid, non-deterministic model cannot gate CI; this checks the scene loop's mechanics, never play quality.
"""Serve a fixed chat-completion reply for the game-scene sample in CI.

Usage: python3 stub_vision.py PORT CONTROL [TOKENS]

Every POST answers {"control": CONTROL} with usage totalling TOKENS (default
24050), so the scene loop's frame, token and verdict mechanics are exercised
deterministically. HTTPServer.server_bind is replaced by TCPServer's: on macOS
runners the stock bind spends ~35 s in socket.getfqdn before listening.
"""

import http.server
import json
import socketserver
import sys


def main():
    port, control = int(sys.argv[1]), sys.argv[2]
    tokens = int(sys.argv[3]) if len(sys.argv) > 3 else 24050
    reply = json.dumps({
        "model": "scene-stub",
        "choices": [{"message": {"content": json.dumps(
            {"control": control, "rationale": "stub"})}}],
        "usage": {"prompt_tokens": tokens - 50, "completion_tokens": 50,
                  "total_tokens": tokens},
    }).encode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)

        def log_message(self, *args):
            pass

    http.server.HTTPServer.server_bind = socketserver.TCPServer.server_bind
    http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
