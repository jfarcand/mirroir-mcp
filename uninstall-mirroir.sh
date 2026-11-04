#!/bin/bash
# ABOUTME: Full uninstaller for mirroir-mcp.
# ABOUTME: Removes binaries, config, and cleans up legacy artifacts from older versions.

set -e

echo "=== Uninstalling mirroir-mcp ==="

# --- Step 1: Remove MCP binary and symlinks ---

echo ""
echo "--- MCP binary ---"

# Remove symlinks from Homebrew bin directories (no sudo needed)
rm -f "/opt/homebrew/bin/mirroir" 2>/dev/null || true
rm -f "/opt/homebrew/bin/mirroir-mcp" 2>/dev/null || true

# Also clean up legacy /usr/local/bin installs (may need sudo)
if [ -L "/usr/local/bin/mirroir" ] || [ -L "/usr/local/bin/mirroir-mcp" ]; then
    sudo rm -f "/usr/local/bin/mirroir-mcp"
    sudo rm -f "/usr/local/bin/mirroir"
fi

echo "MCP binary and symlinks removed."

# --- Step 2: Clean up legacy helper daemon (from pre-CGEvent versions) ---

echo ""
echo "--- Legacy helper daemon cleanup ---"

PLIST_NAME="com.jfarcand.mirroir-helper"

if sudo launchctl list "$PLIST_NAME" >/dev/null 2>&1; then
    echo "Stopping legacy helper daemon..."
    sudo launchctl bootout system/"$PLIST_NAME" 2>/dev/null || true
    sleep 1
fi

# Stop pre-rename daemon if still running
sudo launchctl bootout system/com.jfarcand.iphone-mirroir-helper 2>/dev/null || true

sudo rm -f "/usr/local/bin/mirroir-helper"
sudo rm -f "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo rm -f "/var/run/mirroir-helper.sock"
sudo rm -f "/var/log/mirroir-helper.log"
rm -f "$HOME/.mirroir-mcp/debug.log"

# Clean up pre-rename artifacts
sudo rm -f "/usr/local/bin/iphone-mirroir-mcp"
sudo rm -f "/usr/local/bin/iphone-mirroir-helper"
sudo rm -f "/Library/LaunchDaemons/com.jfarcand.iphone-mirroir-helper.plist"
sudo rm -f "/var/run/iphone-mirroir-helper.sock"
rm -rf "$HOME/.iphone-mirroir-mcp"

echo "Legacy artifacts removed."

# --- Step 3: Remove the agent skill (mirroir-mcp skill --install) ---

echo ""
echo "--- Agent skill ---"

for skill_dir in "$HOME/.claude/skills/mirroir" "${CODEX_HOME:-$HOME/.codex}/skills/mirroir"; do
    # Only the manual mirroir wrote: its heading identifies it.
    if grep -q "^# Driving an iPhone with mirroir" "$skill_dir/SKILL.md" 2>/dev/null; then
        rm -rf "$skill_dir"
        echo "Removed $skill_dir"
    fi
done

# --- Step 4: Remove config directory ---

echo ""
echo "--- Config ---"

MCP_CONFIG_DIR="$HOME/.mirroir-mcp"
if [ -d "$MCP_CONFIG_DIR" ]; then
    read -p "Remove config directory ($MCP_CONFIG_DIR)? [y/N] " remove_config
    case "$remove_config" in
        [yY]*)
            rm -rf "$MCP_CONFIG_DIR"
            echo "Config removed."
            ;;
        *)
            echo "Keeping config."
            ;;
    esac
else
    echo "No config directory found."
fi

echo ""
echo "=== Uninstall complete ==="
