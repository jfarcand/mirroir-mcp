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
    # Wait for launchd to fully release the service before re-bootstrapping
    sleep 2
fi

# Install and load LaunchDaemon plist
sudo cp "Resources/$PLIST_NAME.plist" /Library/LaunchDaemons/
sudo chown root:wheel "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo chmod 644 "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo launchctl bootstrap system "/Library/LaunchDaemons/$PLIST_NAME.plist"

# Verify the daemon is running
echo ""
echo "=== Verifying ==="
if sudo launchctl list "$PLIST_NAME" >/dev/null 2>&1; then
    PID=$(sudo launchctl list "$PLIST_NAME" 2>/dev/null | awk 'NR==2{print $1}')
    echo "Helper daemon is running (PID: ${PID:--})"
else
    echo "WARNING: Helper daemon failed to start. Check logs:"
    echo "  sudo cat /var/log/iphone-mirroir-helper.log"
    exit 1
fi

# Verify the socket is ready (helper needs a moment to create it)
SOCKET="/var/run/iphone-mirroir-helper.sock"
for i in 1 2 3 4 5; do
    if [ -S "$SOCKET" ]; then
        echo "Socket ready: $SOCKET"
        break
    fi
    sleep 1
done
if [ ! -S "$SOCKET" ]; then
    echo "WARNING: Socket not found at $SOCKET after 5s. Check logs:"
    echo "  sudo cat /var/log/iphone-mirroir-helper.log"
fi

echo ""
echo "=== Done ==="
echo "To stop:      sudo launchctl bootout system/$PLIST_NAME"
echo "To uninstall: ./scripts/uninstall-helper.sh"
echo "Logs:         /var/log/iphone-mirroir-helper.log"
