# iphone-mirroir-mcp

MCP server that controls a real iPhone through macOS iPhone Mirroring. Screenshot, tap, swipe, type — from any MCP client.

No simulator. No jailbreak. No app on the phone. Your actual device.

## What Works

- **Screenshots** — captures the mirrored iPhone screen as PNG
- **Taps** — click anywhere on the iPhone screen
- **Swipes** — drag between two points
- **Typing** — type text into any focused text field (US QWERTY)
- **Navigation** — Home, App Switcher, Spotlight via menu bar actions

All input goes through a Karabiner DriverKit virtual HID device, which bypasses iPhone Mirroring's DRM-protected surface.

## Security Warning

**This gives an AI agent full control of your iPhone screen.** It can tap anything, type anything, open any app — autonomously. That includes banking apps, messages, and payments.

The MCP server only works while iPhone Mirroring is active. Closing the window or locking the phone kills all input. The helper daemon listens on a local Unix socket only (no network). The helper runs as root (Karabiner's HID sockets require it) — the full source is ~2500 lines of Swift, audit it yourself.

## Requirements

- macOS 15+ with iPhone Mirroring
- iPhone connected via iPhone Mirroring
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/) installed and activated
- Xcode Command Line Tools (`xcode-select --install`)
- **Screen Recording** + **Accessibility** permissions for your terminal

## Install

### Homebrew (recommended)

```bash
brew install --cask karabiner-elements   # if not already installed
brew tap jfarcand/tap
brew install iphone-mirroir-mcp
sudo brew services start iphone-mirroir-mcp
```

Open Karabiner-Elements and approve the DriverKit extension when prompted. Then run `brew info iphone-mirroir-mcp` and follow the caveats to configure the Karabiner ignore rule and set up your MCP client.

### From source

```bash
brew install --cask karabiner-elements   # if not already installed
git clone https://github.com/jfarcand/iphone-mirroir-mcp.git
cd iphone-mirroir-mcp
./install.sh
```

The installer checks prerequisites, builds both binaries, configures the Karabiner ignore rule automatically, and installs the helper daemon. Prompts for sudo once.

### MCP client config

Add to your `.mcp.json` (Claude Code, Cursor, etc.):

```json
{
  "mcpServers": {
    "iphone-mirroring": {
      "command": "iphone-mirroir-mcp"
    }
  }
}
```

Homebrew installs to `$(brew --prefix)/bin/iphone-mirroir-mcp`.
Source installs to `<repo>/.build/release/iphone-mirroir-mcp` — use the full path.

### Permissions

The first time you run a `screenshot`, macOS prompts for:
- **Screen Recording** — needed to capture the mirroring window
- **Accessibility** — needed for window discovery and menu bar actions

Grant both to your terminal app.

## Tools

| Tool | Parameters | Description |
|------|-----------|-------------|
| `screenshot` | — | Capture the iPhone screen as base64 PNG |
| `tap` | `x`, `y` | Tap at coordinates (relative to mirroring window) |
| `swipe` | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms`? | Swipe between two points (default 300ms) |
| `type_text` | `text` | Type into the focused text field (US QWERTY) |
| `press_home` | — | Go to home screen |
| `press_app_switcher` | — | Open app switcher |
| `spotlight` | — | Open Spotlight search |
| `status` | — | Connection state and device readiness |

Coordinates are in points relative to the mirroring window's top-left corner. Screenshots are Retina 2x — divide pixel coordinates by 2 to get tap coordinates.

## Architecture

```
MCP Client (stdin/stdout JSON-RPC)
    │
    ▼
iphone-mirroir-mcp (user process)
    ├── MirroringBridge    — AXUIElement window discovery + menu actions
    ├── ScreenCapture      — screencapture -l <windowID>
    ├── InputSimulation    — coordinate mapping, focus management
    └── HelperClient       — Unix socket client
            │
            ▼  /var/run/iphone-mirroir-helper.sock
iphone-mirroir-helper (root LaunchDaemon)
    ├── CommandServer      — JSON command dispatch
    └── KarabinerClient    — Karabiner DriverKit virtual HID protocol
            │
            ▼  /Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server/*.sock
    Karabiner DriverKit Extension
            │
            ▼
    macOS HID System → iPhone Mirroring
```

The helper runs as root because Karabiner's virtual HID sockets are in a root-only directory. It creates a virtual keyboard and a virtual pointing device through Karabiner's DriverKit extension. Clicks warp the system cursor to the target, send a Karabiner pointing report, then restore the cursor. Typing clicks the iPhone Mirroring title bar first to ensure keyboard focus, then sends HID keyboard reports.

## Updating

```bash
# Homebrew
brew upgrade iphone-mirroir-mcp
sudo brew services restart iphone-mirroir-mcp

# From source
git pull
sudo ./scripts/reinstall-helper.sh
```

## Uninstall

```bash
# Homebrew
sudo brew services stop iphone-mirroir-mcp
brew uninstall iphone-mirroir-mcp

# From source
./scripts/uninstall-helper.sh
```

## Troubleshooting

**`keyboard_ready: false`** — Karabiner's DriverKit extension isn't running. Open Karabiner-Elements and approve the extension.

**Typing goes to terminal instead of iPhone** — The Karabiner ignore rule is missing. Run `brew info iphone-mirroir-mcp` for the config snippet, or re-run `./install.sh` (source install configures it automatically).

**Taps don't register** — Check that the helper is running:
```bash
echo '{"action":"status"}' | nc -U /var/run/iphone-mirroir-helper.sock
```
If not responding, restart: `sudo brew services restart iphone-mirroir-mcp` or `sudo ./scripts/reinstall-helper.sh`.

**"Mirroring paused" screenshots** — The MCP server auto-resumes paused sessions. If it persists, click the iPhone Mirroring window manually once.

## License

Apache 2.0
