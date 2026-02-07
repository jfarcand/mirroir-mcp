# iphone-mirroir-mcp

An MCP server for testing and automating real iOS apps on a real iPhone through macOS iPhone Mirroring. Screenshot, tap, swipe, type, navigate — over standard MCP stdio transport.

No simulator. No jailbreak. No app installed on the phone. Your actual iPhone, driven by any MCP-compatible agent.

Built for testing iOS apps the way users actually use them — on real hardware, with real performance, real push notifications, real sensors, and real app store builds. But it's a general-purpose iPhone automation bridge, so the use cases go well beyond testing: accessibility auditing, workflow automation, app demos, data extraction, or anything else you can do by touching a screen.

## Security Warning

**This tool gives an AI agent the ability to perform any action on your iPhone that you could perform by touching the screen.** Read this section before installing.

### What this can do

- See everything on your iPhone screen (screenshots)
- Tap anywhere, type anything, swipe in any direction
- Open any app, navigate any UI, interact with any content
- Do all of this autonomously without human-in-the-loop confirmation

### What this means

If you connect this to an AI agent, that agent can:
- Send messages, emails, or payments on your behalf
- Access your banking apps, health data, photos, and private conversations
- Install apps, change settings, or delete data
- Do anything you can do by tapping the screen

### Who should use this

- Developers who need to test iOS apps on real hardware with AI-driven automation
- Teams running end-to-end tests against real devices instead of simulators
- Researchers building agentic systems that interact with real mobile UIs
- Anyone building MCP-based automation who understands the tools they're connecting

### Who should not use this

- Anyone who doesn't understand what MCP tool permissions mean
- Anyone connecting untrusted or unreviewed agents to a phone with sensitive data

### Mitigations

- The MCP server only works while iPhone Mirroring is active and the Mac is unlocked
- Closing the iPhone Mirroring window or locking the phone stops all input
- The MCP server has zero network access — it only communicates via stdin/stdout
- The helper daemon only accepts connections from the local Unix socket (no remote access)
- All agent actions are visible in real-time on the iPhone Mirroring window

### The helper daemon runs as root

The Karabiner helper (`iphone-mirroir-helper`) runs as a LaunchDaemon with root privileges. This is required because Karabiner's virtual HID device sockets are in a root-only directory. The helper:
- Listens on `/var/run/iphone-mirroir-helper.sock` (mode 0666, any local user can connect)
- Can move the mouse cursor and simulate keyboard/mouse input via Karabiner's virtual HID
- Cannot read files, access the network, or do anything beyond cursor/keyboard control
- Source code is ~500 lines across 3 files — audit it yourself before installing

## How it works

iPhone Mirroring (macOS Sequoia+) streams your iPhone screen to a window on your Mac. This MCP server bridges that window:

1. **Screenshots** — macOS `screencapture` targeting the mirroring window by CGWindowID
2. **Taps and swipes** — Karabiner virtual HID (preferred) or CGEvent fallback
3. **Keyboard input** — Karabiner virtual HID keyboard (preferred) or CGEvent fallback
4. **Navigation** — macOS accessibility APIs triggering iPhone Mirroring's menu bar actions

The iPhone screen is an opaque DRM-protected video surface with no accessibility tree. The AI agent uses vision to understand what's on screen and decide where to tap.

### Why Karabiner?

iPhone Mirroring's DRM surface blocks regular CGEvent mouse input in many macOS configurations. The Karabiner DriverKit virtual HID device bypasses this — macOS treats its input as real hardware events. The MCP server falls back to CGEvent automatically when the helper isn't installed.

## Requirements

- macOS 14 (Sonoma) or later
- iPhone Mirroring set up and connected
- Xcode Command Line Tools (`xcode-select --install`)
- **Screen Recording** permission for the terminal/agent process
- **Accessibility** permission for the terminal/agent process
- **Karabiner-Elements** (optional, recommended for reliable input)

## Build

```bash
swift build -c release
```

Two binaries:
- `.build/release/iphone-mirroir-mcp` — MCP server (runs as your user)
- `.build/release/iphone-mirroir-helper` — Karabiner daemon (runs as root)

## Setup

### 1. macOS Permissions

Grant these to whatever process runs the MCP server (your terminal app, IDE, etc.):

**System Settings > Privacy & Security > Screen Recording** — add the app, restart it.

**System Settings > Privacy & Security > Accessibility** — add the app.

### 2. Karabiner Helper (optional, recommended)

Without the helper, taps and typing may not register on the DRM-protected iPhone Mirroring surface. With it, input works reliably.

**Install Karabiner-Elements:**
```bash
brew install --cask karabiner-elements
```
Open Karabiner-Elements Settings and approve the DriverKit system extension when prompted.

**Verify the virtual HID daemon is running:**
```bash
ls /Library/Application\ Support/org.pqrs/tmp/rootonly/vhidd_server/*.sock
```
You should see a `.sock` file. If the directory is empty, open Karabiner-Elements Settings and check that the DriverKit extension is activated.

**Install the helper daemon:**
```bash
./scripts/install-helper.sh
```
This builds the helper, copies it to `/usr/local/bin/`, and loads it as a LaunchDaemon.

**Verify:**
```bash
sudo launchctl list | grep iphone-mirroir   # should show the daemon
cat /var/log/iphone-mirroir-helper.log       # check for errors
```

**Uninstall:**
```bash
./scripts/uninstall-helper.sh
```

### 3. Connect to your agent

Add to your MCP client config (`.mcp.json` or equivalent):

```json
{
  "mcpServers": {
    "iphone-mirroring": {
      "command": "/absolute/path/to/.build/release/iphone-mirroir-mcp"
    }
  }
}
```

## Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| `screenshot` | Capture the iPhone screen as PNG | none |
| `tap` | Tap at coordinates | `x`, `y` (relative to mirroring window) |
| `swipe` | Swipe between two points | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms` |
| `type_text` | Type text into focused field | `text` |
| `press_home` | Go to home screen | none |
| `press_app_switcher` | Open app switcher | none |
| `spotlight` | Open Spotlight search | none |
| `status` | Check mirroring + helper status | none |

## Architecture

```
                                   Unix Socket
stdin (JSON-RPC) -> MCPServer      (JSON IPC)     iphone-mirroir-helper
                        |        <------------>    (LaunchDaemon, root)
           +------------+------------+                    |
           v            v            v              KarabinerClient
    MirroringBridge  ScreenCapture  InputSimulation       |
    (AXUIElement)   (screencapture) (HelperClient)  Karabiner DriverKit
                                    (CGEvent fb)    Virtual HID Device
```

**MCP Server** (your user):
- **MCPServer** — JSON-RPC 2.0 over stdio, tool registry
- **MirroringBridge** — Finds iPhone Mirroring window via AXUIElement, triggers menu actions
- **ScreenCapture** — Captures window via `screencapture -l <windowID>`
- **InputSimulation** — Tries Karabiner helper, falls back to CGEvent
- **HelperClient** — Unix socket client to helper daemon

**Helper Daemon** (root):
- **KarabinerClient** — Wire protocol to Karabiner vhidd over Unix DGRAM sockets
- **CommandServer** — Unix STREAM socket server, dispatches JSON commands, handles CGWarp + Karabiner click/type/swipe

### IPC between MCP server and helper

Newline-delimited JSON over Unix stream socket at `/var/run/iphone-mirroir-helper.sock`:

```
-> {"action":"click","x":1537,"y":444}\n
<- {"ok":true}\n

-> {"action":"type","text":"hello"}\n
<- {"ok":true}\n

-> {"action":"status"}\n
<- {"ok":true,"keyboard_ready":true,"pointing_ready":true}\n
```

### MCP protocol

JSON-RPC 2.0 over stdin/stdout, one JSON object per line:

```
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
<- {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05",...}}

-> {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"tap","arguments":{"x":160,"y":400}}}
<- {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Tapped at (160, 400)"}],"isError":false}}
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
