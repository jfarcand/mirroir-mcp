# iphone-mirroir-mcp

An MCP (Model Context Protocol) server that lets AI assistants control a real iPhone through macOS iPhone Mirroring. Take screenshots, tap, swipe, type, and navigate — all through the standard MCP stdio transport.

## How it works

iPhone Mirroring (macOS Sequoia+) streams your iPhone's screen to a window on your Mac. This MCP server bridges that window to AI assistants like Claude:

1. **Screenshots** via macOS `screencapture` targeting the mirroring window
2. **Taps and swipes** via `CGEvent` mouse events at window-relative coordinates
3. **Keyboard input** via `CGEvent` unicode keyboard events
4. **Navigation** (Home, App Switcher, Spotlight) via accessibility menu actions

The mirrored iPhone content is an opaque video surface — there's no accessibility tree for the iPhone's UI elements. The AI assistant uses its vision capabilities to understand what's on screen and decide where to tap.

## Requirements

- macOS 14 (Sonoma) or later
- iPhone Mirroring set up and working
- Xcode Command Line Tools (for Swift compiler)
- **Screen Recording** permission for the parent process (terminal or Claude Code)
- **Accessibility** permission for the parent process

## Build

```bash
swift build -c release
```

The binary is at `.build/release/iphone-mirroir-mcp`.

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
| `status` | Check mirroring connection state | none |

## Protocol

The server communicates via **JSON-RPC 2.0 over stdin/stdout** (MCP stdio transport). One JSON object per line.

Example session:

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"iphone-mirroir-mcp","version":"0.1.0"}}}

→ {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{}}}
← {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Connected — mirroring active (window: 318x701)"}],"isError":false}}

→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"image","data":"iVBOR...","mimeType":"image/png"}],"isError":false}}
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
stdin (JSON-RPC) → MCPServer → Tool Handlers → macOS APIs → stdout (JSON-RPC)
                                     │
                        ┌────────────┼────────────┐
                        ▼            ▼            ▼
                 MirroringBridge  ScreenCapture  InputSimulation
                 (AXUIElement)   (screencapture) (CGEvent)
```

- **MCPServer** — JSON-RPC 2.0 protocol handler, tool registry
- **MirroringBridge** — Finds iPhone Mirroring window via `AXMainWindow`, detects connection state, triggers menu actions
- **ScreenCapture** — Captures the mirroring window via `screencapture -l <windowID>`
- **InputSimulation** — Sends taps, swipes, and keyboard input via `CGEvent`

### Technical notes

- iPhone Mirroring's window is hidden from `AXWindows` but accessible via `AXMainWindow`
- The mirrored content is a DRM-protected video surface with zero accessibility children
- `CGWindowListCreateImage` is unavailable on macOS 15+; we use `screencapture` CLI instead
- The window may report `isOnScreen: false` even when visible

## License

Apache License 2.0 — see [LICENSE](LICENSE).
