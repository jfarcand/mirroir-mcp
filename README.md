# iphone-mirroir-mcp

MCP server that controls a real iPhone through macOS iPhone Mirroring. Screenshot, tap, swipe, type — from any MCP client.

Works with any app visible on the iPhone screen: App Store apps, TestFlight builds, Expo Go, React Native dev builds — anything you can see in the mirroring window.

## What Works

- **Screenshots** — captures the mirrored iPhone screen as PNG
- **Taps** — click anywhere on the iPhone screen via Karabiner virtual pointing device
- **Swipes** — drag between two points with configurable duration
- **Typing** — type text into any focused field via Karabiner virtual HID keyboard
- **Key presses** — Return, Escape, Tab, arrows, with modifier support (Cmd, Shift, etc.)
- **Navigation** — Home, App Switcher, Spotlight via macOS menu bar actions

All touch and keyboard input flows through Karabiner DriverKit virtual HID devices because iPhone Mirroring routes input through a protected compositor layer that doesn't accept standard CGEvent injection. The MCP server activates iPhone Mirroring once when keyboard input begins (triggering a macOS Space switch if needed) and stays there — no back-and-forth switching between apps.

## Example

```
You:  "Open Messages and send 'hello' to Alice"

Agent: spotlight → type_text "Messages" → press_key return
       → screenshot (sees conversation list)
       → tap on Alice's conversation
       → tap text field → type_text "hello"
       → press_key return → screenshot (verify message sent)
```

## Security Warning

**This gives an AI agent full control of your iPhone screen.** It can tap anything, type anything, open any app — autonomously. That includes banking apps, messages, and payments.

The MCP server only works while iPhone Mirroring is active. Closing the window or locking the phone kills all input. The helper daemon listens on a local Unix socket only (no network). The helper runs as root (Karabiner's HID sockets require it) — the full source is ~2500 lines of Swift, audit it yourself.

## Requirements

- macOS 15+ with iPhone Mirroring
- iPhone connected via iPhone Mirroring
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/) installed and activated

## Install

```bash
brew install --cask karabiner-elements   # if not already installed
brew tap jfarcand/tap
brew install iphone-mirroir-mcp
sudo brew services start iphone-mirroir-mcp
```

Open Karabiner-Elements, select **ANSI** keyboard type, then approve the DriverKit extension: **System Settings > General > Login Items & Extensions** — enable all toggles under Karabiner-Elements. Then add to your `.mcp.json` (Claude Code, Cursor, etc.):

```json
{
  "mcpServers": {
    "iphone-mirroring": {
      "command": "iphone-mirroir-mcp"
    }
  }
}
```

The first time you take a screenshot, macOS will prompt for **Screen Recording** and **Accessibility** permissions. Grant both.

<details>
<summary>Install from source</summary>

```bash
git clone https://github.com/jfarcand/iphone-mirroir-mcp.git
cd iphone-mirroir-mcp
./install.sh
```

The installer handles everything: installs Karabiner if missing (with confirmation), waits for the DriverKit extension approval, builds both binaries, configures the Karabiner ignore rule, installs the helper daemon, and runs a verification check. Use the full path to the binary in your `.mcp.json`: `<repo>/.build/release/iphone-mirroir-mcp`.

</details>

## Tools

| Tool | Parameters | Description |
|------|-----------|-------------|
| `screenshot` | — | Capture the iPhone screen as base64 PNG |
| `tap` | `x`, `y` | Tap at coordinates (relative to mirroring window) |
| `swipe` | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms`? | Swipe between two points (default 300ms) |
| `type_text` | `text` | Type text — activates iPhone Mirroring and sends keystrokes |
| `press_key` | `key`, `modifiers`? | Send a special key (return, escape, tab, delete, space, arrows) with optional modifiers (command, shift, option, control) |
| `press_home` | — | Go to home screen |
| `press_app_switcher` | — | Open app switcher |
| `spotlight` | — | Open Spotlight search |
| `status` | — | Connection state, window geometry, and device readiness |

Coordinates are in points relative to the mirroring window's top-left corner. Screenshots are Retina 2x — divide pixel coordinates by 2 to get tap coordinates.

### Typing workflow

`type_text` and `press_key` route keyboard input through the Karabiner virtual HID keyboard via the helper daemon. If iPhone Mirroring isn't already frontmost, the MCP server activates it once (which may trigger a macOS Space switch) and stays there. Subsequent keyboard tool calls reuse the active window without switching again.

- Characters are mapped to USB HID keycodes (US QWERTY layout)
- Characters without a US QWERTY mapping are skipped and reported in the response
- iOS autocorrect applies — type carefully or disable it on the iPhone

### Key press workflow

`press_key` sends special keys that `type_text` can't handle — navigation keys, Return to submit forms, Escape to dismiss dialogs, Tab to switch fields, arrows to move through lists. Add modifiers for shortcuts like Cmd+N (new message) or Cmd+Z (undo).

For navigating within apps, combine `spotlight` + `type_text` + `press_key`. For example: `spotlight` → `type_text "Messages"` → `press_key return` → `press_key {"key":"n","modifiers":["command"]}` to open a new conversation.

## Architecture

```
MCP Client (stdin/stdout JSON-RPC)
    │
    ▼
iphone-mirroir-mcp (user process)
    ├── MirroringBridge    — AXUIElement window discovery + menu actions
    ├── ScreenCapture      — screencapture -l <windowID>
    ├── InputSimulation    — activate-once + coordinate mapping
    │       ├── type_text  → activate if needed → HelperClient type
    │       ├── press_key  → activate if needed → HelperClient press_key
    │       └── tap/swipe  → HelperClient (Unix socket IPC)
    └── HelperClient       — Unix socket client
            │
            ▼  /var/run/iphone-mirroir-helper.sock
iphone-mirroir-helper (root LaunchDaemon)
    ├── CommandServer      — JSON command dispatch (click/type/press_key/swipe/move)
    └── KarabinerClient    — Karabiner DriverKit virtual HID protocol
            │
            ▼  /Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server/*.sock
    Karabiner DriverKit Extension
            │
            ▼
    macOS HID System → iPhone Mirroring
```

**Taps/swipes**: The helper warps the system cursor to the target coordinates, sends a Karabiner virtual pointing device button press, then restores the cursor. iPhone Mirroring's compositor layer requires input through the system HID path rather than programmatic CGEvent injection.

**Typing/key presses**: The MCP server activates iPhone Mirroring via AppleScript System Events (the only reliable way to trigger a macOS Space switch), then sends HID keycodes through the helper's Karabiner virtual keyboard. Activation only happens when iPhone Mirroring isn't already frontmost, and the server does not restore the previous app — this eliminates the per-keystroke Space switching of earlier versions.

**Navigation**: Home, Spotlight, and App Switcher use macOS Accessibility APIs to trigger iPhone Mirroring's menu bar actions directly (no window focus needed).

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

# From source — removes helper daemon, Karabiner config changes,
# and optionally Karabiner-Elements itself
./uninstall.sh
```

## Troubleshooting

**`keyboard_ready: false`** — Karabiner's DriverKit extension isn't running. Open Karabiner-Elements, then go to **System Settings > General > Login Items & Extensions** and enable all toggles under Karabiner-Elements. You may need to enter your password.

**Typing goes to the wrong app instead of iPhone** — Make sure you're running v0.4.0+. The MCP server activates iPhone Mirroring via AppleScript before sending keystrokes through Karabiner. If this still fails, check that your terminal app has Accessibility permissions in System Settings.

**Taps don't register** — Check that the helper is running:
```bash
echo '{"action":"status"}' | nc -U /var/run/iphone-mirroir-helper.sock
```
If not responding, restart: `sudo brew services restart iphone-mirroir-mcp` or `sudo ./scripts/reinstall-helper.sh`.

**"Mirroring paused" screenshots** — The MCP server auto-resumes paused sessions. If it persists, click the iPhone Mirroring window manually once.

**iOS autocorrect mangling typed text** — iOS applies autocorrect to typed text. Disable autocorrect in iPhone Settings > General > Keyboard, or type words followed by spaces to confirm them before autocorrect triggers.

## License

Apache 2.0
