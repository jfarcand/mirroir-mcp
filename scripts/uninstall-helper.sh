#!/bin/bash
# ABOUTME: Uninstalls the iphone-mirroir-helper LaunchDaemon and removes files.
# ABOUTME: Requires sudo for removal from /usr/local/bin and /Library/LaunchDaemons.

set -e

PLIST_NAME="com.jfarcand.iphone-mirroir-helper"
HELPER_BIN="iphone-mirroir-helper"

echo "=== Uninstalling iphone-mirroir-helper ==="

# Stop and unload daemon
if sudo launchctl list "$PLIST_NAME" >/dev/null 2>&1; then
    echo "Stopping daemon..."
    sudo launchctl bootout system/"$PLIST_NAME" 2>/dev/null || true
fi

# Remove files
sudo rm -f "/usr/local/bin/$HELPER_BIN"
sudo rm -f "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo rm -f "/var/run/iphone-mirroir-helper.sock"
sudo rm -f "/var/log/iphone-mirroir-helper.log"

echo "Helper daemon uninstalled."
