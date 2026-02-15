#!/bin/bash
# ABOUTME: Curl-pipe-bash installer that clones the repo and delegates to mirroir.sh.
# ABOUTME: Usage: curl -fsSL https://raw.githubusercontent.com/jfarcand/iphone-mirroir-mcp/main/get-mirroir.sh | bash

set -e

REPO="https://github.com/jfarcand/iphone-mirroir-mcp.git"
INSTALL_DIR="${IPHONE_MIRROIR_HOME:-$HOME/iphone-mirroir-mcp}"

echo "=== iphone-mirroir-mcp installer ==="
echo ""

# --- Check prerequisites ---

if ! command -v git >/dev/null 2>&1; then
    echo "Error: git not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "Error: Swift not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

# --- Clone or update ---

if [ -d "$INSTALL_DIR" ]; then
    if [ -d "$INSTALL_DIR/.git" ]; then
        echo "Updating existing installation at $INSTALL_DIR..."
        git -C "$INSTALL_DIR" pull --ff-only
    else
        echo "Error: $INSTALL_DIR exists but is not a git repository."
        echo "Remove it or set IPHONE_MIRROIR_HOME to a different path."
        exit 1
    fi
else
    echo "Cloning to $INSTALL_DIR..."
    git clone "$REPO" "$INSTALL_DIR"
fi

echo ""

# Delegate to mirroir.sh, reopening stdin from the terminal so interactive
# prompts (e.g. "Install Karabiner? [Y/n]") work when piped through curl.
exec "$INSTALL_DIR/mirroir.sh" </dev/tty
