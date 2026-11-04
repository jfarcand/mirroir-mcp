# ABOUTME: Test-only stand-in for the scene vision model: an OpenAI-shaped /v1/chat/completions with a fixed reply.
# ABOUTME: Names one control, or (--reading) only reads the frame for a decider-driven scene; never judges play quality.
"""Serve a fixed chat-completion reply for the board-scene sample in CI.

Usage: python3 stub_vision.py PORT (CONTROL | --reading) [TOKENS]

Every POST answers with usage totalling TOKENS (default 24050). With CONTROL
the reply is {"control": CONTROL, "rationale": "stub"}, the shape a scene
without a decider expects. With --reading it is {"reading": "stub",
"rationale": "stub"}, the shape a `decider: required` scene expects: the model
only reads the frame and the stub decider picks the move. HTTPServer.server_bind
is replaced by TCPServer's: on macOS runners the stock bind spends ~35 s in
socket.getfqdn before listening.
"""

import http.server
import json
import socketserver
import sys

READING_MODE = "--reading"


def main():
    port, mode = int(sys.argv[1]), sys.argv[2]
    tokens = int(sys.argv[3]) if len(sys.argv) > 3 else 24050
    if mode == READING_MODE:
        content = {"reading": "stub", "rationale": "stub"}
    else:
        content = {"control": mode, "rationale": "stub"}
    reply = json.dumps({
        "model": "scene-stub",
        "choices": [{"message": {"content": json.dumps(content)}}],
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
