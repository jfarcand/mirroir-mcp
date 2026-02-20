#!/bin/bash
# ABOUTME: One-step installer for iphone-mirroir-mcp.
# ABOUTME: Installs standalone DriverKit virtual HID (or reuses existing Karabiner-Elements), builds binaries, and verifies setup.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.jfarcand.iphone-mirroir-helper"
HELPER_BIN="iphone-mirroir-helper"
MCP_BIN="iphone-mirroir-mcp"
KARABINER_CONFIG="$HOME/.config/karabiner/karabiner.json"
KARABINER_SOCK_DIR="/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server"
KARABINER_WAIT_TIMEOUT=120

DRIVERKIT_VERSION="6.10.0"
DRIVERKIT_PKG="Karabiner-DriverKit-VirtualHIDDevice-${DRIVERKIT_VERSION}.pkg"
DRIVERKIT_URL="https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v${DRIVERKIT_VERSION}/${DRIVERKIT_PKG}"
DRIVERKIT_MANAGER="/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"

cd "$SCRIPT_DIR"

# --- Step 1: Check prerequisites ---

echo "=== Checking prerequisites ==="

if ! command -v swift >/dev/null 2>&1; then
    echo "Error: Swift not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

echo "Swift: $(swift --version 2>&1 | head -1)"

# --- Step 2: Ensure DriverKit virtual HID is available ---

if ! sudo bash -c "ls '$KARABINER_SOCK_DIR'/*.sock" >/dev/null 2>&1; then
    if [ -d "/Applications/Karabiner-Elements.app" ]; then
        echo ""
        echo "Karabiner-Elements is installed but the DriverKit extension is not running."
        echo "To approve the DriverKit system extension:"
        echo "  1. Open Karabiner-Elements"
        echo "  2. Open System Settings > General > Login Items & Extensions"
        echo "  3. Under 'Karabiner-Elements', enable all toggles"
        echo "  4. Enter your password when prompted"
    elif [ -f "$DRIVERKIT_MANAGER" ]; then
        echo ""
        echo "Standalone DriverKit is installed but the extension is not running."
        echo "Activating..."
        "$DRIVERKIT_MANAGER" activate
        echo ""
        echo "Approve the system extension in System Settings:"
        echo "  System Settings > General > Login Items & Extensions"
        echo "  Enable the Karabiner-DriverKit-VirtualHIDDevice toggle"
    else
        echo ""
        echo "A DriverKit virtual HID device is required for tap and swipe input."
        read -p "Install standalone Karabiner DriverKit package? [Y/n] " answer
        case "$answer" in
            [nN]*) echo "Skipping. Install manually from: https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases"; exit 1 ;;
        esac

        echo "Downloading Karabiner-DriverKit-VirtualHIDDevice v${DRIVERKIT_VERSION}..."
        TMP_PKG="/tmp/${DRIVERKIT_PKG}"
        curl -fSL -o "$TMP_PKG" "$DRIVERKIT_URL"

        echo "Installing..."
        sudo installer -pkg "$TMP_PKG" -target /
        rm -f "$TMP_PKG"

        if [ ! -f "$DRIVERKIT_MANAGER" ]; then
            echo "Error: DriverKit Manager not found after install."
            echo "Try downloading manually from:"
            echo "  https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases"
            exit 1
        fi

        echo ""
        echo "Activating DriverKit system extension..."
        "$DRIVERKIT_MANAGER" activate
        echo ""
        echo "Approve the system extension in System Settings:"
        echo "  System Settings > General > Login Items & Extensions"
        echo "  Enable the Karabiner-DriverKit-VirtualHIDDevice toggle"
        echo ""
        echo "If macOS shows a 'System Extension Blocked' alert, click"
        echo "'Open System Settings' and approve it there."
    fi

    echo ""
    echo "Waiting for DriverKit extension (up to ${KARABINER_WAIT_TIMEOUT}s)..."
    elapsed=0
    while ! sudo bash -c "ls '$KARABINER_SOCK_DIR'/*.sock" >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$KARABINER_WAIT_TIMEOUT" ]; then
            echo ""
            echo "Timed out waiting for DriverKit extension."
            echo "Approve the extension in System Settings and re-run this script."
            exit 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        printf "\r  waiting... %ds" "$elapsed"
    done
    printf "\r  ready.            \n"
fi

echo "DriverKit: running"

# --- Step 3: Build ---

echo ""
echo "=== Building ==="
swift build -c release

echo "Built: .build/release/$MCP_BIN"
echo "Built: .build/release/$HELPER_BIN"

# Create mirroir symlink for ergonomic CLI access
ln -sf "$MCP_BIN" ".build/release/mirroir"
echo "Symlink: .build/release/mirroir -> $MCP_BIN"

# --- Step 4: Configure Karabiner ignore rule (only when Karabiner-Elements is installed) ---
# The ignore rule prevents Karabiner's keyboard grabber from intercepting our virtual keyboard.
# With standalone DriverKit there is no grabber, so the rule is unnecessary.

echo ""
echo "=== Configuring Karabiner ==="

if [ -d "/Applications/Karabiner-Elements.app" ]; then
    IGNORE_RULE='{"identifiers":{"is_keyboard":true,"product_id":592,"vendor_id":1452},"ignore":true}'

    if [ -f "$KARABINER_CONFIG" ]; then
        if grep -q '"product_id": 592' "$KARABINER_CONFIG" 2>/dev/null || \
           grep -q '"product_id":592' "$KARABINER_CONFIG" 2>/dev/null; then
            echo "Karabiner ignore rule already configured."
        else
            # Add the device ignore rule to the first profile
            python3 -c "
import json, sys
with open('$KARABINER_CONFIG') as f:
    config = json.load(f)
profile = config['profiles'][0]
if 'devices' not in profile:
    profile['devices'] = []
profile['devices'].append(json.loads('$IGNORE_RULE'))
with open('$KARABINER_CONFIG', 'w') as f:
    json.dump(config, f, indent=4)
print('Added device ignore rule to Karabiner config.')
"
        fi
    else
        mkdir -p "$(dirname "$KARABINER_CONFIG")"
        cat > "$KARABINER_CONFIG" << 'KARABINER_EOF'
{
    "profiles": [
        {
            "devices": [
                {
                    "identifiers": {
                        "is_keyboard": true,
                        "product_id": 592,
                        "vendor_id": 1452
                    },
                    "ignore": true
                }
            ],
            "name": "Default profile",
            "selected": true,
            "virtual_hid_keyboard": { "keyboard_type_v2": "ansi" }
        }
    ]
}
KARABINER_EOF
        echo "Created Karabiner config with device ignore rule."
    fi
else
    echo "Using standalone DriverKit (no Karabiner grabber, ignore rule not needed)."
fi

# --- Step 5: Install helper daemon ---

echo ""
echo "=== Installing helper daemon (requires sudo) ==="

sudo cp ".build/release/$HELPER_BIN" /usr/local/bin/
sudo chmod 755 "/usr/local/bin/$HELPER_BIN"

# Install mirroir CLI symlink for ergonomic command-line access
MCP_FULL_PATH="$(pwd)/.build/release/$MCP_BIN"
sudo ln -sf "$MCP_FULL_PATH" /usr/local/bin/mirroir
echo "Installed: /usr/local/bin/mirroir -> $MCP_FULL_PATH"

if sudo launchctl list "$PLIST_NAME" >/dev/null 2>&1; then
    echo "Stopping existing daemon..."
    sudo launchctl bootout system/"$PLIST_NAME" 2>/dev/null || true
    sleep 1
fi

sudo cp "Resources/$PLIST_NAME.plist" /Library/LaunchDaemons/
sudo chown root:wheel "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo chmod 644 "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo launchctl bootstrap system "/Library/LaunchDaemons/$PLIST_NAME.plist"

# Wait for helper to start and verify — the daemon may need several restarts
# via KeepAlive before the Karabiner virtual HID device becomes ready
HELPER_SOCK="/var/run/iphone-mirroir-helper.sock"
HELPER_TIMEOUT=30
echo "Waiting for helper daemon (up to ${HELPER_TIMEOUT}s)..."
elapsed=0
STATUS=""
while [ "$elapsed" -lt "$HELPER_TIMEOUT" ]; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ -S "$HELPER_SOCK" ]; then
        STATUS=$(echo '{"action":"status"}' | nc -U "$HELPER_SOCK" 2>/dev/null || echo "")
        if [ -n "$STATUS" ] && echo "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('ok') else 1)" 2>/dev/null; then
            break
        fi
    fi
    printf "\r  waiting... %ds" "$elapsed"
done
printf "\r                    \n"

# --- Step 6: Install prompts and agent profiles ---

echo ""
echo "=== Installing prompts and agent profiles ==="

GLOBAL_CONFIG_DIR="$HOME/.iphone-mirroir-mcp"
mkdir -p "$GLOBAL_CONFIG_DIR/prompts" "$GLOBAL_CONFIG_DIR/agents"

# Copy prompts (skip if user has customized)
for f in prompts/*.md; do
    [ -f "$f" ] || continue
    dest="$GLOBAL_CONFIG_DIR/prompts/$(basename "$f")"
    if [ ! -f "$dest" ]; then
        cp "$f" "$dest"
        echo "  Installed: $dest"
    else
        echo "  Skipped (user-customized): $dest"
    fi
done

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

# --- Step 7: Verify setup ---

echo ""
echo "=== Verifying setup ==="

PASS=0
FAIL=0

# Check helper daemon is responding with valid JSON
if [ -n "$STATUS" ] && echo "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'ok' in d" 2>/dev/null; then
    echo "  [ok] Helper daemon is running"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] Helper daemon not responding"
    FAIL=$((FAIL + 1))
fi

# Check virtual pointing device (informational — may take time after fresh install)
if [ -n "$STATUS" ] && echo "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('pointing_ready') else 1)" 2>/dev/null; then
    echo "  [ok] Virtual pointing device ready"
    PASS=$((PASS + 1))
else
    echo "  [warn] Virtual pointing device not ready yet"
    echo "         Approve the DriverKit extension in System Settings > General > Login Items & Extensions."
    PASS=$((PASS + 1))
fi

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
