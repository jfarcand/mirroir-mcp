#!/bin/zsh
# ABOUTME: Development watcher that rebuilds and restarts the MCP server on source changes.
# ABOUTME: Uses fswatch to monitor Sources/ and triggers swift build + restart.

set -euo pipefail

BINARY_NAME="mirroir-mcp"
WATCH_DIR="Sources/"

# Pass through all arguments to the server (e.g. --debug, --dangerously-skip-permissions)
SERVER_ARGS=("$@")

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

if ! command -v fswatch &>/dev/null; then
    echo "fswatch not found. Install it with: brew install fswatch" >&2
    exit 1
fi

start_server() {
    swift run "$BINARY_NAME" "${SERVER_ARGS[@]}" &
    SERVER_PID=$!
    echo "[watch] Server started (PID $SERVER_PID)"
}

# Initial build and start
echo "[watch] Building..."
swift build
start_server

# Watch for changes, rebuild and restart
fswatch -o --latency 1 -e '.*' -i '\\.swift$' "$WATCH_DIR" | while read -r _; do
    echo "[watch] Change detected, rebuilding..."
    if swift build; then
        echo "[watch] Build succeeded, restarting server..."
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        start_server
    else
        echo "[watch] Build failed, server unchanged."
    fi
done
