# iphone-mirroir-mcp

MCP server that controls a real iPhone through macOS iPhone Mirroring. Screenshot, tap, swipe, type — from any MCP client.

**Test your Expo and React Native apps on a real device, driven by an AI agent.** No simulator limitations. No jailbreak. No app installed on the phone. Your actual device, with real push notifications, real GPS, real camera — everything the simulator can't do.

## Why Real Device Testing?

Simulators miss real-world issues: push notifications don't fire, GPS is faked, camera APIs are stubbed, performance differs, and native modules behave differently. With `iphone-mirroir-mcp`, an AI agent can drive your actual iPhone — tap through flows, type into fields, verify screens — exactly as your users experience it.

Works with any app visible on the iPhone screen: Expo Go, React Native dev builds, TestFlight builds, or production apps from the App Store.

## What Works

- **Screenshots** — captures the mirrored iPhone screen as PNG
- **Taps** — click anywhere on the iPhone screen via Karabiner virtual pointing device
- **Swipes** — drag between two points with configurable duration
- **Typing** — type text into any focused field via AppleScript System Events
- **Key presses** — Return, Escape, Tab, arrows, with modifier support (Cmd, Shift, etc.)
- **Navigation** — Home, App Switcher, Spotlight via macOS menu bar actions

Taps and swipes use a Karabiner DriverKit virtual pointing device because iPhone Mirroring routes input through a protected compositor layer that doesn't accept standard CGEvent injection. Typing and key presses use AppleScript to activate the window and send keystrokes through System Events.

## Example: Testing an Expo App

```
You:  "Open my Expo app and test the login flow"

Agent: spotlight → type_text "Expo Go" → press_key return
       → screenshot (sees the app list)
       → tap on your project
       → screenshot (sees login screen)
       → tap email field → type_text "test@example.com"
       → tap password field → type_text "hunter2"
       → tap "Sign In" → screenshot (verify dashboard loaded)
```

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

Open Karabiner-Elements and approve the DriverKit extension when prompted. Then run `brew info iphone-mirroir-mcp` and follow the caveats to configure your MCP client.

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
| `type_text` | `text` | Type text — activates iPhone Mirroring and sends keystrokes |
| `press_key` | `key`, `modifiers`? | Send a special key (return, escape, tab, delete, space, arrows) with optional modifiers (command, shift, option, control) |
| `press_home` | — | Go to home screen |
| `press_app_switcher` | — | Open app switcher |
| `spotlight` | — | Open Spotlight search |
| `status` | — | Connection state, window geometry, and device readiness |

Coordinates are in points relative to the mirroring window's top-left corner. Screenshots are Retina 2x — divide pixel coordinates by 2 to get tap coordinates.

### Typing workflow

`type_text` activates iPhone Mirroring as the frontmost app via System Events, then sends keystrokes. This means:
- The iPhone Mirroring window takes focus briefly during typing
- After typing, your previous app regains focus
- Works with any keyboard layout (not limited to US QWERTY)
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
    ├── InputSimulation    — AppleScript typing/key presses, coordinate mapping
    │       ├── type_text  → System Events: set frontmost + keystroke
    │       ├── press_key  → System Events: set frontmost + key code
    │       └── tap/swipe  → HelperClient (Unix socket IPC)
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

**Taps/swipes**: The helper warps the system cursor to the target coordinates, sends a Karabiner virtual pointing device button press, then restores the cursor. iPhone Mirroring's compositor layer requires input through the system HID path rather than programmatic CGEvent injection.

**Typing/key presses**: The MCP server uses AppleScript to set iPhone Mirroring as frontmost via System Events, then sends `keystroke` or `key code` commands. This routes input to iPhone Mirroring without needing the Karabiner virtual keyboard.

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

# From source
./scripts/uninstall-helper.sh
```

## Troubleshooting

**`keyboard_ready: false`** — Karabiner's DriverKit extension isn't running. Open Karabiner-Elements and approve the extension.

**Typing goes to terminal instead of iPhone** — Make sure you're running v0.3.0+. Older versions used Karabiner HID keyboard which sent keystrokes to whatever had focus. v0.3.0 uses AppleScript to activate iPhone Mirroring before typing.

**Taps don't register** — Check that the helper is running:
```bash
echo '{"action":"status"}' | nc -U /var/run/iphone-mirroir-helper.sock
```
If not responding, restart: `sudo brew services restart iphone-mirroir-mcp` or `sudo ./scripts/reinstall-helper.sh`.

**"Mirroring paused" screenshots** — The MCP server auto-resumes paused sessions. If it persists, click the iPhone Mirroring window manually once.

**iOS autocorrect mangling typed text** — iOS applies autocorrect to typed text. Disable autocorrect in iPhone Settings > General > Keyboard, or type words followed by spaces to confirm them before autocorrect triggers.

## License

Apache 2.0
