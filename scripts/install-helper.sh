#!/bin/bash
# ABOUTME: Builds and installs the iphone-mirroir-helper as a LaunchDaemon.
# ABOUTME: Requires sudo for installation into /usr/local/bin and /Library/LaunchDaemons.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PLIST_NAME="com.jfarcand.iphone-mirroir-helper"
HELPER_BIN="iphone-mirroir-helper"
SOCKET="/var/run/iphone-mirroir-helper.sock"
LOG="/var/log/iphone-mirroir-helper.log"

echo "=== Building iphone-mirroir-helper ==="
cd "$PROJECT_DIR"

# Build as the real user, not root. Running `swift build` as root creates
# root-owned artifacts in .build/ that block subsequent user builds.
if [ "$(id -u)" -eq 0 ] && [ -n "$SUDO_USER" ]; then
    sudo -u "$SUDO_USER" swift build -c release --product "$HELPER_BIN"
else
    swift build -c release --product "$HELPER_BIN"
fi

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

# Remove stale socket from previous run
sudo rm -f "$SOCKET"

# Install and load LaunchDaemon plist
sudo cp "Resources/$PLIST_NAME.plist" /Library/LaunchDaemons/
sudo chown root:wheel "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo chmod 644 "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo launchctl bootstrap system "/Library/LaunchDaemons/$PLIST_NAME.plist"

# Verify the daemon registered with launchd
echo ""
echo "=== Verifying ==="
if ! sudo launchctl list "$PLIST_NAME" >/dev/null 2>&1; then
    echo "FAILED: Helper daemon did not register with launchd."
    echo "  Check logs: sudo cat $LOG"
    exit 1
fi
echo "Daemon registered with launchd"

# Wait for Karabiner virtual HID initialization and socket creation.
# Karabiner needs ~30-40s after a fresh restart to activate both keyboard
# and pointing devices. The helper blocks on this before opening the socket.
echo "Waiting for Karabiner virtual HID initialization (this takes ~30s)..."
MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if [ -S "$SOCKET" ]; then
        break
    fi

    # Check if the daemon is still alive
    if ! sudo launchctl list "$PLIST_NAME" >/dev/null 2>&1; then
        echo ""
        echo "FAILED: Helper daemon exited during Karabiner initialization."
        echo "  Check logs: sudo cat $LOG"
        exit 1
    fi

    sleep 2
    WAITED=$((WAITED + 2))
    printf "\r  %ds / %ds" "$WAITED" "$MAX_WAIT"
done
echo ""

if [ ! -S "$SOCKET" ]; then
    echo "FAILED: Socket not found after ${MAX_WAIT}s."
    echo "  Karabiner-Elements may not be installed or its DriverKit extension is not activated."
    echo "  Check logs: sudo cat $LOG"
    exit 1
fi

echo "Socket ready: $SOCKET"

echo ""
echo "=== Done ==="
echo "Helper daemon installed and ready."
echo "To stop:      sudo launchctl bootout system/$PLIST_NAME"
echo "To uninstall: ./scripts/uninstall-helper.sh"
echo "Logs:         $LOG"
