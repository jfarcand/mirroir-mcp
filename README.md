# iphone-mirroir-mcp

## Why iPhone Mirroring?

MCP server that controls a real iPhone through macOS iPhone Mirroring. Screenshot, tap, swipe, type — from any MCP client.

Works with any app visible on the iPhone screen: App Store apps, TestFlight builds, Expo Go, React Native dev builds — anything you can see in the mirroring window.

Every other iPhone automation tool requires Appium, Xcode, WebDriverAgent, and a provisioning profile. This project takes a different approach: it controls the iPhone through macOS iPhone Mirroring using Karabiner virtual HID devices. No Xcode. No developer account. No provisioning profile.

This means you can test real apps on a real device — Expo Go, Flutter, React Native dev builds, TestFlight betas, App Store apps — directly on your iPhone without a simulator. The AI agent sees exactly what a real user sees and interacts with the same touch targets, autocorrect, and keyboard behavior.

## Requirements

- macOS 15+ with iPhone Mirroring
- iPhone connected via iPhone Mirroring
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/) installed and activated

## Install

One command sets up everything — Karabiner, helper daemon, and your MCP client config:

```bash
npx -y iphone-mirroir-mcp install
```

The installer prompts you to select your MCP client (Claude Code, Cursor, GitHub Copilot, or OpenAI Codex) and writes the config automatically.

After install, approve the DriverKit extension if prompted: **System Settings > General > Login Items & Extensions** — enable all toggles under Karabiner-Elements. The first time you take a screenshot, macOS will prompt for **Screen Recording** and **Accessibility** permissions. Grant both.

<details>
<summary>Manual per-client setup</summary>

#### Claude Code

```bash
claude mcp add --transport stdio iphone-mirroring -- npx -y iphone-mirroir-mcp
```

#### Cursor

Add to `.cursor/mcp.json` in your project root:

```json
{
  "mcpServers": {
    "iphone-mirroring": {
      "command": "npx",
      "args": ["-y", "iphone-mirroir-mcp"]
    }
  }
}
```

#### GitHub Copilot (VS Code)

Add to `.vscode/mcp.json` in your workspace:

```json
{
  "servers": {
    "iphone-mirroring": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "iphone-mirroir-mcp"]
    }
  }
}
```

#### OpenAI Codex

```bash
codex mcp add iphone-mirroring -- npx -y iphone-mirroir-mcp
```

Or add to `~/.codex/config.toml`:

```toml
[mcp_servers.iphone-mirroring]
command = "npx"
args = ["-y", "iphone-mirroir-mcp"]
```

#### Helper daemon only

If your MCP client is already configured but the helper daemon isn't running:

```bash
npx iphone-mirroir-mcp setup
```

</details>

<details>
<summary>Homebrew</summary>

```bash
brew install --cask karabiner-elements   # if not already installed
brew tap jfarcand/tap
brew install iphone-mirroir-mcp
sudo brew services start iphone-mirroir-mcp
```

Then point your MCP client to the binary at `iphone-mirroir-mcp` (it's in your PATH after `brew install`).

</details>

<details>
<summary>Install from source</summary>

```bash
git clone https://github.com/jfarcand/iphone-mirroir-mcp.git
cd iphone-mirroir-mcp
./install.sh
```

The installer handles everything: installs Karabiner if missing (with confirmation), waits for the DriverKit extension approval, builds both binaries, configures the Karabiner ignore rule, installs the helper daemon, and runs a verification check. Use the full path to the binary in your `.mcp.json`: `<repo>/.build/release/iphone-mirroir-mcp`.

</details>

## What Works

| Feature | Description |
|---------|-------------|
| Screenshots | Capture the mirrored iPhone screen as PNG |
| Screen analysis | OCR-based element detection with tap coordinates and grid overlay for targeting unlabeled icons |
| Video recording | Record the mirrored screen as .mov files |
| Taps | Click anywhere on the iPhone screen via Karabiner virtual pointing device |
| Swipes | Drag between two points with configurable duration |
| Long press | Hold tap for context menus and drag initiation |
| Double tap | Two rapid taps for zoom and text selection |
| Drag | Slow sustained drag for rearranging icons, adjusting sliders |
| Typing | Type text into any focused field via Karabiner virtual HID keyboard with non-US layout support |
| Key presses | Return, Escape, Tab, arrows, with modifier support (Cmd, Shift, etc.) |
| Navigation | Home, App Switcher, Spotlight via macOS menu bar actions |
| App launch | Open any app by name via Spotlight search |
| URL opening | Navigate to any URL in Safari |
| Shake gesture | Trigger shake-to-undo and developer menus |
| Orientation | Report portrait/landscape and window dimensions |

All touch and keyboard input flows through Karabiner DriverKit virtual HID devices because iPhone Mirroring routes input through a protected compositor layer that doesn't accept standard CGEvent injection. The MCP server activates iPhone Mirroring once when keyboard input begins (triggering a macOS Space switch if needed) and stays there — no back-and-forth switching between apps.

## Examples

```
You:  "Open Messages and send 'hello' to Alice"

Agent: launch_app "Messages"
       → screenshot (sees conversation list)
       → tap on Alice's conversation
       → tap text field → type_text "hello"
       → press_key return → screenshot (verify sent)
```

```
You:  "Test the login flow in my Expo app"

Agent: launch_app "Expo Go"
       → screenshot (sees project list)
       → tap on the project → screenshot (sees login screen)
       → tap email field → type_text "test@example.com"
       → tap password field → type_text "password123"
       → tap "Sign In" button → screenshot (verify logged in)
```

```
You:  "Record a video of scrolling through the Settings app"

Agent: start_recording
       → launch_app "Settings" → screenshot
       → swipe up to scroll → swipe up again
       → tap "General" → screenshot
       → stop_recording (returns .mov file path)
```

## Security Warning

**This gives an AI agent full control of your iPhone screen.** It can tap anything, type anything, open any app — autonomously. That includes banking apps, messages, and payments.

The MCP server only works while iPhone Mirroring is active. Closing the window or locking the phone kills all input. The helper daemon listens on a local Unix socket only (no network). The helper runs as root (Karabiner's HID sockets require it) — the full source is ~2500 lines of Swift, audit it yourself.

**Threat model**: The helper socket (`/var/run/iphone-mirroir-helper.sock`) is restricted to `root:staff` with mode 0660. On macOS, all interactive user accounts belong to the `staff` group, so any local user on the machine can send commands to the helper. This is appropriate for single-user Macs (the target use case). On shared machines, any local user account could drive the iPhone screen. There is no authentication handshake — the socket permission is the only access control.

See [Permissions](#permissions) below to control which tools the MCP server exposes.

## Permissions

The server is **fail-closed by default**. Without a config file, only readonly tools are exposed to the MCP client:

| Always allowed | Requires permission |
|---------------|-------------------|
| `screenshot`, `describe_screen`, `start_recording`, `stop_recording`, `get_orientation`, `status` | `tap`, `swipe`, `drag`, `type_text`, `press_key`, `long_press`, `double_tap`, `shake`, `launch_app`, `open_url`, `press_home`, `press_app_switcher`, `spotlight` |

Mutating tools are hidden from `tools/list` entirely — the MCP client never sees them unless you allow them.

### Config file

Create `~/.config/iphone-mirroir-mcp/permissions.json`:

```json
{
  "allow": ["tap", "swipe", "type_text", "press_key", "launch_app"],
  "deny": [],
  "blockedApps": []
}
```

- **`allow`** — whitelist of mutating tools to expose (case-insensitive). Use `["*"]` to allow all.
- **`deny`** — blocklist that overrides allow. A tool in both lists is denied.
- **`blockedApps`** — app names that `launch_app` refuses to open (case-insensitive).

### Examples

Allow all mutating tools:

```json
{
  "allow": ["*"]
}
```

Allow tapping and typing, block banking apps:

```json
{
  "allow": ["tap", "swipe", "type_text", "press_key", "describe_screen"],
  "deny": ["shake"],
  "blockedApps": ["Wallet", "PayPal", "Venmo"]
}
```

Block Instagram from being launched:

```json
{
  "allow": ["*"],
  "blockedApps": ["Instagram"]
}
```

### CLI flags

For development and testing, bypass the permission system entirely:

```bash
npx -y iphone-mirroir-mcp --dangerously-skip-permissions
npx -y iphone-mirroir-mcp --yolo   # alias
```

Both flags expose all tools regardless of config. Do not use in production.

## Debug Mode

Pass `--debug` to enable verbose logging:

```bash
npx -y iphone-mirroir-mcp --debug
```

Logs are written to both stderr and `/tmp/iphone-mirroir-mcp-debug.log` (truncated on each startup). Logged events include permission checks, tap coordinates, focus state, and window geometry.

Tail the log in a separate terminal:

```bash
tail -f /tmp/iphone-mirroir-mcp-debug.log
```

Combine with permission bypass for full-access debugging:

```bash
npx -y iphone-mirroir-mcp --debug --yolo
```

## Tools

| Tool | Parameters | Description |
|------|-----------|-------------|
| `screenshot` | — | Capture the iPhone screen as base64 PNG |
| `describe_screen` | — | OCR the screen and return text elements with tap coordinates plus a grid-overlaid screenshot |
| `start_recording` | `output_path`? | Start video recording of the mirrored screen |
| `stop_recording` | — | Stop recording and return the .mov file path |
| `tap` | `x`, `y` | Tap at coordinates (relative to mirroring window) |
| `double_tap` | `x`, `y` | Two rapid taps for zoom/text selection |
| `long_press` | `x`, `y`, `duration_ms`? | Hold tap for context menus (default 500ms) |
| `swipe` | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms`? | Swipe between two points (default 300ms) |
| `drag` | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms`? | Slow sustained drag for icons, sliders (default 1000ms) |
| `type_text` | `text` | Type text — activates iPhone Mirroring and sends keystrokes |
| `press_key` | `key`, `modifiers`? | Send a special key (return, escape, tab, delete, space, arrows) with optional modifiers (command, shift, option, control) |
| `shake` | — | Trigger shake gesture (Ctrl+Cmd+Z) for undo/dev menus |
| `launch_app` | `name` | Open app by name via Spotlight search |
| `open_url` | `url` | Open URL in Safari |
| `press_home` | — | Go to home screen |
| `press_app_switcher` | — | Open app switcher |
| `spotlight` | — | Open Spotlight search |
| `get_orientation` | — | Report portrait/landscape and window dimensions |
| `status` | — | Connection state, window geometry, and device readiness |

Coordinates are in points relative to the mirroring window's top-left corner. Use `describe_screen` to get exact tap coordinates via OCR — its grid overlay also helps target unlabeled icons (back arrows, stars, gears) that OCR can't detect. For raw screenshots, coordinates are Retina 2x — divide pixel coordinates by 2 to get tap coordinates.

### Typing workflow

`type_text` and `press_key` route keyboard input through the Karabiner virtual HID keyboard via the helper daemon. If iPhone Mirroring isn't already frontmost, the MCP server activates it once (which may trigger a macOS Space switch) and stays there. Subsequent keyboard tool calls reuse the active window without switching again.

- Characters are mapped to USB HID keycodes with automatic keyboard layout translation — non-US layouts (French AZERTY, German QWERTZ, etc.) are supported via UCKeyTranslate
- **Known limitation**: On ISO keyboards (e.g., Canadian-CSA), a small number of characters tied to the ISO section key (`§`, `±`) cannot be typed via HID because macOS and iOS swap keycodes 0x64 and 0x35 differently. These characters are silently skipped. Clipboard paste is not available — iPhone Mirroring does not bridge the Mac clipboard when paste is triggered programmatically.
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
    ├── PermissionPolicy   — fail-closed tool gating (config + CLI flags)
    ├── MirroringBridge    — AXUIElement window discovery + menu actions
    ├── ScreenCapture      — screencapture -l <windowID>
    ├── ScreenDescriber    — Vision OCR + coordinate grid overlay
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

