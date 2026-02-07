#!/bin/bash
# ABOUTME: Builds and installs the iphone-mirroir-helper as a LaunchDaemon.
# ABOUTME: Requires sudo for installation into /usr/local/bin and /Library/LaunchDaemons.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PLIST_NAME="com.jfarcand.iphone-mirroir-helper"
HELPER_BIN="iphone-mirroir-helper"

echo "=== Building iphone-mirroir-helper ==="
cd "$PROJECT_DIR"
swift build -c release --product "$HELPER_BIN"

echo ""
echo "=== Installing helper (requires sudo) ==="

# Install binary
sudo cp ".build/release/$HELPER_BIN" /usr/local/bin/
sudo chmod 755 "/usr/local/bin/$HELPER_BIN"
echo "Installed /usr/local/bin/$HELPER_BIN"

# Unload existing daemon if present
if sudo launchctl list "$PLIST_NAME" >/dev/null 2>&1; then
    echo "Stopping existing daemon..."
    sudo launchctl bootout system/"$PLIST_NAME" 2>/dev/null || true
fi

# Install and load LaunchDaemon plist
sudo cp "Resources/$PLIST_NAME.plist" /Library/LaunchDaemons/
sudo chown root:wheel "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo chmod 644 "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo launchctl bootstrap system "/Library/LaunchDaemons/$PLIST_NAME.plist"

echo ""
echo "=== Done ==="
echo "Helper daemon installed and running."
echo "Logs: /var/log/iphone-mirroir-helper.log"
echo "MCP server: .build/release/iphone-mirroir-mcp"
echo ""
echo "To check status: sudo launchctl list | grep iphone-mirroir"
echo "To stop:         sudo launchctl bootout system/$PLIST_NAME"
echo "To uninstall:    ./scripts/uninstall-helper.sh"
