#!/bin/bash
# ABOUTME: One-step installer for iphone-mirroir-mcp.
# ABOUTME: Installs Karabiner if needed, builds both binaries, configures everything, and verifies the setup.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.jfarcand.iphone-mirroir-helper"
HELPER_BIN="iphone-mirroir-helper"
MCP_BIN="iphone-mirroir-mcp"
KARABINER_CONFIG="$HOME/.config/karabiner/karabiner.json"
KARABINER_SOCK_DIR="/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server"
KARABINER_WAIT_TIMEOUT=120

cd "$SCRIPT_DIR"

# --- Step 1: Check prerequisites ---

echo "=== Checking prerequisites ==="

if ! command -v swift >/dev/null 2>&1; then
    echo "Error: Swift not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

echo "Swift: $(swift --version 2>&1 | head -1)"

if ! command -v brew >/dev/null 2>&1; then
    echo "Error: Homebrew not found. Install it from https://brew.sh"
    exit 1
fi

# --- Step 2: Install Karabiner-Elements if missing ---

if ! ls "$KARABINER_SOCK_DIR"/*.sock >/dev/null 2>&1; then
    if [ -d "/Applications/Karabiner-Elements.app" ]; then
        echo ""
        echo "Karabiner-Elements is installed but the DriverKit extension is not running."
        echo "Open Karabiner-Elements and approve the system extension when prompted."
    else
        echo ""
        echo "Karabiner-Elements is required for tap and swipe input."
        read -p "Install it now via Homebrew? [Y/n] " answer
        case "$answer" in
            [nN]*) echo "Skipping. Install manually: brew install --cask karabiner-elements"; exit 1 ;;
        esac
        brew install --cask karabiner-elements
        echo ""
        echo "Karabiner-Elements installed. Opening it now..."
        open -a "Karabiner-Elements"
        echo "Approve the system extension when macOS prompts you."
    fi

    echo ""
    echo "Waiting for Karabiner DriverKit extension (up to ${KARABINER_WAIT_TIMEOUT}s)..."
    elapsed=0
    while ! ls "$KARABINER_SOCK_DIR"/*.sock >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$KARABINER_WAIT_TIMEOUT" ]; then
            echo ""
            echo "Timed out waiting for Karabiner DriverKit extension."
            echo "Open Karabiner-Elements, approve the extension, and re-run this script."
            exit 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        printf "\r  waiting... %ds" "$elapsed"
    done
    printf "\r  ready.            \n"
fi

echo "Karabiner: running"

# --- Step 3: Build ---

echo ""
echo "=== Building ==="
swift build -c release

echo "Built: .build/release/$MCP_BIN"
echo "Built: .build/release/$HELPER_BIN"

# --- Step 4: Configure Karabiner ignore rule ---

echo ""
echo "=== Configuring Karabiner ==="

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

# --- Step 5: Install helper daemon ---

echo ""
echo "=== Installing helper daemon (requires sudo) ==="

sudo cp ".build/release/$HELPER_BIN" /usr/local/bin/
sudo chmod 755 "/usr/local/bin/$HELPER_BIN"

if sudo launchctl list "$PLIST_NAME" >/dev/null 2>&1; then
    echo "Stopping existing daemon..."
    sudo launchctl bootout system/"$PLIST_NAME" 2>/dev/null || true
    sleep 1
fi

sudo cp "Resources/$PLIST_NAME.plist" /Library/LaunchDaemons/
sudo chown root:wheel "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo chmod 644 "/Library/LaunchDaemons/$PLIST_NAME.plist"
sudo launchctl bootstrap system "/Library/LaunchDaemons/$PLIST_NAME.plist"

# Wait for helper to start and verify
sleep 2
STATUS=$(echo '{"action":"status"}' | nc -U /var/run/iphone-mirroir-helper.sock 2>/dev/null || echo "")

# --- Step 6: Verify setup ---

echo ""
echo "=== Verifying setup ==="

PASS=0
FAIL=0

# Check helper daemon
if [ -n "$STATUS" ] && echo "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('ok') else 1)" 2>/dev/null; then
    echo "  [ok] Helper daemon is running"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] Helper daemon not responding"
    FAIL=$((FAIL + 1))
fi

# Check Karabiner pointing device
if [ -n "$STATUS" ] && echo "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('pointing_ready') else 1)" 2>/dev/null; then
    echo "  [ok] Karabiner virtual pointing device ready"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] Karabiner virtual pointing device not ready"
    FAIL=$((FAIL + 1))
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
fi

echo ""
echo "Add to your MCP client config (.mcp.json):"
echo ""
echo "  {"
echo "    \"mcpServers\": {"
echo "      \"iphone-mirroring\": {"
echo "        \"command\": \"$MCP_PATH\""
echo "      }"
echo "    }"
echo "  }"
echo ""
echo "The first time you take a screenshot, macOS will prompt for"
echo "Screen Recording and Accessibility permissions. Grant both."
