#!/bin/bash
# ABOUTME: Reinstall the helper daemon with the latest build.
# ABOUTME: Must be run as root (sudo ./scripts/reinstall-helper.sh).

set -e

BINARY_SRC=".build/release/iphone-mirroir-helper"
BINARY_DST="/usr/local/bin/iphone-mirroir-helper"
PLIST="/Library/LaunchDaemons/com.jfarcand.iphone-mirroir-helper.plist"
LABEL="com.jfarcand.iphone-mirroir-helper"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (sudo $0)"
    exit 1
fi

if [ ! -f "$BINARY_SRC" ]; then
    echo "Error: $BINARY_SRC not found. Run 'swift build -c release' first."
    exit 1
fi

echo "Stopping helper..."
launchctl bootout "system/$LABEL" 2>/dev/null || true

echo "Copying binary..."
cp "$BINARY_SRC" "$BINARY_DST"
chmod 755 "$BINARY_DST"

echo "Starting helper..."
launchctl bootstrap system "$PLIST"

sleep 2
echo "Checking status..."
echo '{"action":"status"}' | nc -U /var/run/iphone-mirroir-helper.sock
echo ""
echo "Done."
