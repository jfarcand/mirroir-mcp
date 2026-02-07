# iphone-mirroir-mcp

An MCP (Model Context Protocol) server that lets AI assistants control a real iPhone through macOS iPhone Mirroring. Take screenshots, tap, swipe, type, and navigate — all through the standard MCP stdio transport.

## How it works

iPhone Mirroring (macOS Sequoia+) streams your iPhone's screen to a window on your Mac. This MCP server bridges that window to AI assistants like Claude:

1. **Screenshots** via macOS `screencapture` targeting the mirroring window
2. **Taps and swipes** via Karabiner virtual HID device (preferred) or `CGEvent` fallback
3. **Keyboard input** via Karabiner virtual HID keyboard (preferred) or `CGEvent` fallback
4. **Navigation** (Home, App Switcher, Spotlight) via accessibility menu actions

The mirrored iPhone content is an opaque video surface — there's no accessibility tree for the iPhone's UI elements. The AI assistant uses its vision capabilities to understand what's on screen and decide where to tap.

### Why Karabiner?

iPhone Mirroring's DRM-protected surface can block regular `CGEvent` input in some macOS configurations. The Karabiner virtual HID approach bypasses this by sending input through a DriverKit virtual keyboard/mouse, which macOS treats as real hardware input. The MCP server automatically falls back to CGEvent when the Karabiner helper is not installed.

## Requirements

- macOS 14 (Sonoma) or later
- iPhone Mirroring set up and working
- Xcode Command Line Tools (for Swift compiler)
- **Screen Recording** permission for the parent process (terminal or Claude Code)
- **Accessibility** permission for the parent process
- **Karabiner-Elements** (optional but recommended — enables reliable input on DRM surfaces)

## Build

```bash
swift build -c release
```

This produces two binaries:
- `.build/release/iphone-mirroir-mcp` — the MCP server (runs as your user)
- `.build/release/iphone-mirroir-helper` — the Karabiner helper daemon (runs as root)

## Karabiner Helper Setup (recommended)

The helper daemon communicates with Karabiner's virtual HID device to deliver input that works reliably on iPhone Mirroring's DRM-protected surface.

### Prerequisites

1. Install Karabiner-Elements: `brew install --cask karabiner-elements`
2. Open Karabiner-Elements Settings and approve the DriverKit system extension
3. Verify the virtual HID daemon is running:
   ```bash
   ls /Library/Application\ Support/org.pqrs/tmp/rootonly/vhidd_server/*.sock
   ```

### Install the helper

```bash
./scripts/install-helper.sh
```

This builds the helper, copies it to `/usr/local/bin/`, and installs a LaunchDaemon that keeps it running.

### Verify

```bash
# Check the daemon is running
sudo launchctl list | grep iphone-mirroir

# Check logs
cat /var/log/iphone-mirroir-helper.log
```

### Uninstall

```bash
./scripts/uninstall-helper.sh
```

### Without the helper

The MCP server works without the helper — it falls back to CGEvent-based input. The `status` tool reports whether the helper is connected.

## Usage with Claude Code

Add to your `.mcp.json`:

```json
{
  "mcpServers": {
    "iphone-mirroring": {
      "command": "/path/to/iphone-mirroir-mcp"
    }
  }
}
```

Then Claude can interact with your iPhone:

> "Take a screenshot of my iPhone"
> "Open the Settings app"
> "Type 'hello' in the search field"

## Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| `screenshot` | Capture the mirroring window as PNG | none |
| `tap` | Tap at coordinates on the iPhone | `x`, `y` |
| `swipe` | Swipe gesture between two points | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms` |
| `type_text` | Type text via keyboard events | `text` |
| `press_home` | Go to iPhone home screen | none |
| `press_app_switcher` | Open the app switcher | none |
| `spotlight` | Open Spotlight search | none |
| `status` | Check mirroring and helper connection state | none |

## Protocol

The server communicates via **JSON-RPC 2.0 over stdin/stdout** (MCP stdio transport). One JSON object per line.

Example session:

```
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
<- {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"iphone-mirroir-mcp","version":"0.1.0"}}}

-> {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{}}}
<- {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Connected — mirroring active (window: 318x701)\nHelper: connected (keyboard=true, pointing=true)"}],"isError":false}}

-> {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}
<- {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"image","data":"iVBOR...","mimeType":"image/png"}],"isError":false}}
```

## Permissions setup

### Screen Recording

The process running the MCP server needs Screen Recording permission:

1. Open **System Settings > Privacy & Security > Screen Recording**
2. Add your terminal app (iTerm, Terminal.app, etc.) or Claude Code
3. **Restart the app** after toggling the permission

### Accessibility

The process also needs Accessibility permission for window detection and menu actions:

1. Open **System Settings > Privacy & Security > Accessibility**
2. Add your terminal app or Claude Code

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

### Components

**MCP Server** (user process):
- **MCPServer** — JSON-RPC 2.0 protocol handler, tool registry
- **MirroringBridge** — Finds iPhone Mirroring window via `AXMainWindow`, detects connection state, triggers menu actions
- **ScreenCapture** — Captures the mirroring window via `screencapture -l <windowID>`
- **InputSimulation** — Delegates input to HelperClient (Karabiner), falls back to CGEvent
- **HelperClient** — Unix socket client communicating with the helper daemon

**Helper Daemon** (root process):
- **KarabinerClient** — Implements the Karabiner vhidd wire protocol over Unix datagram sockets
- **CommandServer** — Unix stream socket server accepting JSON commands, dispatches to KarabinerClient with CGWarp cursor positioning

### IPC Protocol

The MCP server and helper communicate via newline-delimited JSON over a Unix stream socket at `/var/run/iphone-mirroir-helper.sock`.

Request: `{"action":"click","x":1537,"y":444}\n`
Response: `{"ok":true}\n`

### Technical notes

- iPhone Mirroring's window is hidden from `AXWindows` but accessible via `AXMainWindow`
- The mirrored content is a DRM-protected video surface with zero accessibility children
- `CGWindowListCreateImage` is unavailable on macOS 15+; we use `screencapture` CLI instead
- The window may report `isOnScreen: false` even when visible
- The Karabiner helper uses `SOCK_DGRAM` Unix sockets to communicate with `vhidd_server`
- Click sequence: save cursor -> CGWarp to target -> Karabiner nudge -> button down -> 80ms -> button up -> restore cursor

## License

Apache License 2.0 — see [LICENSE](LICENSE).
