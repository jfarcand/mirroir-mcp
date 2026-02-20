#!/bin/bash
# ABOUTME: Development script that removes ALL mirroir and Karabiner components for clean-slate testing.
# ABOUTME: Logs every step so output can be shared for debugging. Requires sudo.

set -e

LOG_FILE="/tmp/mirroir-dev-uninstall-$(date +%Y%m%d-%H%M%S).log"

log() {
    local msg="[$(date +%H:%M:%S)] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

run() {
    log "  RUN: $*"
    if eval "$@" >> "$LOG_FILE" 2>&1; then
        log "  OK"
    else
        log "  SKIP (exit $?)"
    fi
}

echo "Full uninstall log: $LOG_FILE"
echo ""

# --- Phase 1: Helper daemon ---

log "=== Phase 1: Helper daemon ==="

run "sudo launchctl bootout system/com.jfarcand.iphone-mirroir-helper 2>/dev/null || true"
sleep 1

run "sudo rm -f /usr/local/bin/iphone-mirroir-helper"
run "sudo rm -f /usr/local/bin/mirroir"
run "sudo rm -f /Library/LaunchDaemons/com.jfarcand.iphone-mirroir-helper.plist"
run "sudo rm -f /var/run/iphone-mirroir-helper.sock"
run "sudo rm -f /var/log/iphone-mirroir-helper.log"
run "rm -f '$HOME/.iphone-mirroir-mcp/debug.log'"

log "Helper daemon removed."

# --- Phase 2: Karabiner-Elements ---

log ""
log "=== Phase 2: Karabiner-Elements ==="

run 'osascript -e "quit app \"Karabiner-Elements\"" 2>/dev/null || true'
sleep 1

if brew list --cask karabiner-elements >/dev/null 2>&1; then
    log "Removing via Homebrew (--zap)..."
    run "brew uninstall --zap --cask karabiner-elements 2>/dev/null || true"
else
    log "Not installed via Homebrew."
fi

log "Stopping user agents..."
for agent in \
    org.pqrs.service.agent.Karabiner-Menu \
    org.pqrs.service.agent.Karabiner-Core-Service \
    org.pqrs.service.agent.Karabiner-NotificationWindow \
    org.pqrs.service.agent.karabiner_console_user_server \
    org.pqrs.service.agent.karabiner_session_monitor; do
    run "launchctl remove '$agent' 2>/dev/null || true"
done

log "Stopping system daemons..."
for daemon in \
    org.pqrs.Karabiner-DriverKit-VirtualHIDDeviceClient \
    org.pqrs.karabiner.karabiner_core_service \
    org.pqrs.karabiner.karabiner_session_monitor; do
    run "sudo launchctl bootout system/'$daemon' 2>/dev/null || true"
done

log "Killing remaining processes..."
run "sudo killall Karabiner-VirtualHIDDevice-Daemon 2>/dev/null || true"
run "sudo killall Karabiner-Core-Service 2>/dev/null || true"
run "killall Karabiner-Elements 2>/dev/null || true"
run "killall Karabiner-Menu 2>/dev/null || true"
run "killall Karabiner-NotificationWindow 2>/dev/null || true"
run "killall karabiner_console_user_server 2>/dev/null || true"
run "sudo killall karabiner_session_monitor 2>/dev/null || true"
sleep 1

log "Removing launch plists..."
run "sudo rm -f /Library/LaunchDaemons/org.pqrs.*.plist"
run "sudo rm -f /Library/LaunchAgents/org.pqrs.*.plist"
run "rm -f '$HOME/Library/LaunchAgents'/org.pqrs.*.plist 2>/dev/null || true"

log "Removing applications..."
run "sudo rm -rf /Applications/Karabiner-Elements.app"
run "sudo rm -rf /Applications/Karabiner-EventViewer.app"

log "Removing user config..."
run "rm -rf '$HOME/.config/karabiner'"

log "Karabiner-Elements removed."

# --- Phase 3: Standalone DriverKit ---

log ""
log "=== Phase 3: Standalone DriverKit ==="

DRIVERKIT_MANAGER="/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"
if [ -f "$DRIVERKIT_MANAGER" ]; then
    log "Deactivating system extension..."
    run "'$DRIVERKIT_MANAGER' deactivate 2>/dev/null || true"
    run "sudo rm -rf '/Applications/.Karabiner-VirtualHIDDevice-Manager.app'"
    log "Standalone DriverKit removed."
else
    log "No standalone DriverKit found."
fi

# --- Phase 3b: Final cleanup of org.pqrs support files ---
# Must happen AFTER DriverKit deactivation. The DriverKit kernel extension
# recreates directories while running, so we kill remaining processes, wait
# briefly for the extension to wind down, then remove.

log ""
log "=== Phase 3b: Final org.pqrs cleanup ==="

run "sudo killall Karabiner-VirtualHIDDevice-Daemon 2>/dev/null || true"
log "Waiting 3s for DriverKit extension to wind down..."
sleep 3
run "sudo rm -rf '/Library/Application Support/org.pqrs'"

# If the kernel extension recreated it again, try once more
if [ -d "/Library/Application Support/org.pqrs" ]; then
    log "Directory recreated by kernel extension — retrying..."
    sleep 2
    run "sudo rm -rf '/Library/Application Support/org.pqrs'"
fi

# --- Phase 4: Verify clean state ---

log ""
log "=== Phase 4: Verify clean state ==="

PASS=0
FAIL=0

check() {
    local label="$1"
    local condition="$2"
    if eval "$condition" >/dev/null 2>&1; then
        log "  [FAIL] $label"
        FAIL=$((FAIL + 1))
    else
        log "  [OK]   $label"
        PASS=$((PASS + 1))
    fi
}

check "No Karabiner-Elements.app" "test -d /Applications/Karabiner-Elements.app"
check "No Karabiner-EventViewer.app" "test -d /Applications/Karabiner-EventViewer.app"
check "No standalone DriverKit Manager" "test -f '$DRIVERKIT_MANAGER'"
check "No vhidd sockets" "sudo bash -c \"ls '/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server'/*.sock\" 2>/dev/null"
check "No org.pqrs support dir" "test -d '/Library/Application Support/org.pqrs'"
check "No Karabiner config" "test -f '$HOME/.config/karabiner/karabiner.json'"
check "No helper daemon socket" "test -S /var/run/iphone-mirroir-helper.sock"
check "No helper binary" "test -f /usr/local/bin/iphone-mirroir-helper"
check "No mirroir symlink" "test -L /usr/local/bin/mirroir"
check "No helper plist" "test -f /Library/LaunchDaemons/com.jfarcand.iphone-mirroir-helper.plist"

REMAINING=$(ps aux | grep -i -e karabiner -e "org.pqrs" | grep -v grep | wc -l | tr -d ' ')
if [ "$REMAINING" -le 1 ]; then
    log "  [OK]   No Karabiner processes (DriverKit kernel ext persists until reboot)"
    PASS=$((PASS + 1))
else
    log "  [WARN] $REMAINING Karabiner process(es) still running (DriverKit kernel ext persists until reboot)"
    PASS=$((PASS + 1))
fi

log ""
if [ "$FAIL" -eq 0 ]; then
    log "=== Clean slate: $PASS checks passed, 0 failed ==="
else
    log "=== $FAIL check(s) failed, $PASS passed ==="
fi

log ""
log "Log saved to: $LOG_FILE"
log "Ready to test: ./mirroir.sh"
