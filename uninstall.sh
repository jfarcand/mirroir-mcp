#!/bin/bash
# ABOUTME: Full uninstaller for iphone-mirroir-mcp.
# ABOUTME: Removes helper daemon, Karabiner config changes, and optionally Karabiner-Elements itself.

set -e

PLIST_NAME="com.jfarcand.iphone-mirroir-helper"
HELPER_BIN="iphone-mirroir-helper"
KARABINER_CONFIG="$HOME/.config/karabiner/karabiner.json"

echo "=== Uninstalling iphone-mirroir-mcp ==="

# --- Step 1: Stop and remove helper daemon ---

echo ""
echo "--- Helper daemon ---"

if sudo launchctl list "$PLIST_NAME" >/dev/null 2>&1; then
    echo "Stopping daemon..."
    sudo launchctl bootout system/"$PLIST_NAME" 2>/dev/null || true
    sleep 1
fi

sudo rm -f "/usr/local/bin/$HELPER_BIN"
sudo rm -f "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo rm -f "/var/run/iphone-mirroir-helper.sock"
sudo rm -f "/var/log/iphone-mirroir-helper.log"
rm -f "/tmp/iphone-mirroir-mcp-debug.log"
echo "Helper daemon removed."

# --- Step 2: Remove permissions config ---

echo ""
echo "--- Permissions config ---"

MCP_CONFIG_DIR="$HOME/.iphone-mirroir-mcp"
if [ -d "$MCP_CONFIG_DIR" ]; then
    read -p "Remove permissions config ($MCP_CONFIG_DIR)? [y/N] " remove_config
    case "$remove_config" in
        [yY]*)
            rm -rf "$MCP_CONFIG_DIR"
            echo "Permissions config removed."
            ;;
        *)
            echo "Keeping permissions config."
            ;;
    esac
else
    echo "No permissions config found."
fi

# --- Step 3: Remove Karabiner ignore rule ---

echo ""
echo "--- Karabiner config ---"

if [ -f "$KARABINER_CONFIG" ]; then
    if grep -q '"product_id": 592' "$KARABINER_CONFIG" 2>/dev/null || \
       grep -q '"product_id":592' "$KARABINER_CONFIG" 2>/dev/null; then
        python3 -c "
import json
with open('$KARABINER_CONFIG') as f:
    config = json.load(f)
for profile in config.get('profiles', []):
    devices = profile.get('devices', [])
    profile['devices'] = [
        d for d in devices
        if not (d.get('identifiers', {}).get('product_id') == 592
                and d.get('identifiers', {}).get('vendor_id') == 1452)
    ]
with open('$KARABINER_CONFIG', 'w') as f:
    json.dump(config, f, indent=4)
print('Removed iPhone Mirroring ignore rule from Karabiner config.')
"
    else
        echo "No iPhone Mirroring ignore rule found in Karabiner config."
    fi
else
    echo "No Karabiner config found."
fi

# --- Step 4: Optionally remove Karabiner-Elements ---

# Detect Karabiner by app, brew cask, or running processes
KARABINER_INSTALLED=false
if [ -d "/Applications/Karabiner-Elements.app" ]; then
    KARABINER_INSTALLED=true
elif brew list --cask karabiner-elements >/dev/null 2>&1; then
    KARABINER_INSTALLED=true
elif ps aux | grep -i "Karabiner" | grep -v grep >/dev/null 2>&1; then
    KARABINER_INSTALLED=true
fi

echo ""
if [ "$KARABINER_INSTALLED" = true ]; then
    read -p "Also uninstall Karabiner-Elements? [y/N] " answer
    case "$answer" in
        [yY]*)
            echo ""
            echo "--- Removing Karabiner-Elements ---"

            # Uninstall via Homebrew if installed that way
            if brew list --cask karabiner-elements >/dev/null 2>&1; then
                echo "Removing Homebrew cask..."
                brew uninstall --zap --cask karabiner-elements 2>/dev/null || true
            fi

            # Quit the GUI app
            osascript -e 'quit app "Karabiner-Elements"' 2>/dev/null || true
            sleep 1

            # Stop user-level agents
            for agent in \
                org.pqrs.service.agent.Karabiner-Menu \
                org.pqrs.service.agent.Karabiner-Core-Service \
                org.pqrs.service.agent.Karabiner-NotificationWindow \
                org.pqrs.service.agent.karabiner_console_user_server \
                org.pqrs.service.agent.karabiner_session_monitor; do
                launchctl remove "$agent" 2>/dev/null || true
            done

            # Stop system-level daemons
            for daemon in \
                org.pqrs.Karabiner-DriverKit-VirtualHIDDeviceClient \
                org.pqrs.karabiner.karabiner_core_service \
                org.pqrs.karabiner.karabiner_session_monitor; do
                sudo launchctl bootout system/"$daemon" 2>/dev/null || true
            done

            # Kill any remaining Karabiner processes directly
            sudo killall Karabiner-VirtualHIDDevice-Daemon 2>/dev/null || true
            sudo killall Karabiner-Core-Service 2>/dev/null || true
            killall Karabiner-Elements 2>/dev/null || true
            killall Karabiner-Menu 2>/dev/null || true
            killall Karabiner-NotificationWindow 2>/dev/null || true
            killall karabiner_console_user_server 2>/dev/null || true
            sudo killall karabiner_session_monitor 2>/dev/null || true
            sleep 1

            # Remove launch plists (before files, so daemons don't restart)
            sudo rm -f /Library/LaunchDaemons/org.pqrs.*.plist
            sudo rm -f /Library/LaunchAgents/org.pqrs.*.plist
            rm -f "$HOME/Library/LaunchAgents"/org.pqrs.*.plist 2>/dev/null || true

            # Remove applications
            sudo rm -rf /Applications/Karabiner-Elements.app
            sudo rm -rf /Applications/Karabiner-EventViewer.app

            # Remove support files
            sudo rm -rf "/Library/Application Support/org.pqrs"

            # Remove user config
            rm -rf "$HOME/.config/karabiner"

            # Verify cleanup
            remaining=$(ps aux | grep -i -e karabiner -e "org.pqrs" | grep -v grep | wc -l)
            if [ "$remaining" -gt 1 ]; then
                echo "Karabiner-Elements removed."
                echo "Note: The DriverKit kernel extension (1 process) persists until reboot."
            else
                echo "Karabiner-Elements fully removed."
            fi
            ;;
        *)
            echo "Keeping Karabiner-Elements installed."
            ;;
    esac
fi

echo ""
echo "=== Uninstall complete ==="
