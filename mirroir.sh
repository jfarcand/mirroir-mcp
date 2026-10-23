#!/bin/bash
# ABOUTME: One-step installer for mirroir-mcp.
# ABOUTME: Builds the MCP server binary, installs agent profiles, and verifies setup.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_BIN="mirroir-mcp"

cd "$SCRIPT_DIR"

# --- Step 1: Check prerequisites ---

echo "=== Checking prerequisites ==="

if ! command -v swift >/dev/null 2>&1; then
    echo "Error: Swift not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

echo "Swift: $(swift --version 2>&1 | head -1)"

# --- Step 2: Build ---

echo ""
echo "=== Building ==="
swift build -c release

echo "Built: .build/release/$MCP_BIN"

# Create mirroir symlink for ergonomic CLI access
ln -sf "$MCP_BIN" ".build/release/mirroir"
echo "Symlink: .build/release/mirroir -> $MCP_BIN"

# Install mirroir CLI symlink to Homebrew bin directory (no sudo needed)
MCP_FULL_PATH="$(pwd)/.build/release/$MCP_BIN"
if [ -d "/opt/homebrew/bin" ]; then
    INSTALL_BIN="/opt/homebrew/bin"
elif [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    INSTALL_BIN="/usr/local/bin"
else
    INSTALL_BIN=""
fi

if [ -n "$INSTALL_BIN" ]; then
    ln -sf "$MCP_FULL_PATH" "$INSTALL_BIN/mirroir"
    echo "Installed: $INSTALL_BIN/mirroir -> $MCP_FULL_PATH"
else
    echo "Note: Could not find a writable bin directory on PATH."
    echo "  Add .build/release/ to your PATH, or symlink manually:"
    echo "  ln -sf $MCP_FULL_PATH /usr/local/bin/mirroir"
fi

# --- Step 3: Configure keyboard layout ---

echo ""
echo "=== Configuring ==="
"$MCP_FULL_PATH" configure

# --- Step 4: Install agent profiles ---

echo ""
echo "=== Installing agent profiles ==="

GLOBAL_CONFIG_DIR="$HOME/.mirroir-mcp"
mkdir -p "$GLOBAL_CONFIG_DIR/agents"

# Copy agent profiles (skip if user has customized)
for f in agents/*.yaml; do
    [ -f "$f" ] || continue
    dest="$GLOBAL_CONFIG_DIR/agents/$(basename "$f")"
    if [ ! -f "$dest" ]; then
        cp "$f" "$dest"
        echo "  Installed: $dest"
    else
        echo "  Skipped (user-customized): $dest"
    fi
done

# --- Step 5: Verify setup ---

echo ""
echo "=== Verifying setup ==="

PASS=0
FAIL=0

# Check MCP binary
MCP_PATH="$(pwd)/.build/release/$MCP_BIN"
if [ -x "$MCP_PATH" ]; then
    echo "  [ok] MCP server binary built"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] MCP server binary not found"
    FAIL=$((FAIL + 1))
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== All $PASS checks passed ==="
else
    echo "=== $FAIL check(s) failed, $PASS passed ==="
    echo "See Troubleshooting in README.md"
    exit 1
fi

echo ""
echo "Add to your MCP client config (.mcp.json):"
echo ""
echo "  {"
echo "    \"mcpServers\": {"
echo "      \"mirroir\": {"
echo "        \"command\": \"$MCP_PATH\""
echo "      }"
echo "    }"
echo "  }"
echo ""
echo "The first time you take a screenshot, macOS will prompt for"
echo "Screen Recording and Accessibility permissions. Grant both."
