# iphone-mirroir-mcp

[![npm version](https://img.shields.io/npm/v/iphone-mirroir-mcp)](https://www.npmjs.com/package/iphone-mirroir-mcp)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](https://support.apple.com/en-us/105071)

MCP server that controls a real iPhone through macOS iPhone Mirroring. Screenshot, tap, swipe, type — from any MCP client. No Xcode, no simulator, no provisioning profile. Works with any app visible on the iPhone screen: App Store apps, TestFlight builds, Expo Go, React Native dev builds.

Input flows through [Karabiner](https://karabiner-elements.pqrs.org/) DriverKit virtual HID devices because iPhone Mirroring blocks standard CGEvent injection.

## Requirements

- macOS 15+
- iPhone connected via [iPhone Mirroring](https://support.apple.com/en-us/105071)

## Install

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

## Examples

Paste any of these into Claude Code, Cursor, or any MCP client:

**Send an iMessage:**

```
Open Messages, find my conversation with Alice, and send "running 10 min late".
Take a screenshot so I can confirm it was sent.
```

**Add a calendar event:**

```
Open Calendar, create a new event called "Dentist" next Tuesday at 2pm,
and screenshot the week view so I can see it.
```

**Test a login flow:**

```
Open my Expo Go app, tap on the "LoginDemo" project, and test the login
screen. Use test@example.com / password123. Take a screenshot after each step
so I can see what happened.
```

**Record a bug repro video:**

```
Start recording, open Settings, scroll down to General > About, then stop
recording. I need a video of the scroll lag I'm seeing.
```

## Security Warning

**This gives an AI agent full control of your iPhone screen.** It can tap anything, type anything, open any app — autonomously. That includes banking apps, messages, and payments.

The MCP server only works while iPhone Mirroring is active. Closing the window or locking the phone kills all input. The helper daemon listens on a local Unix socket only (no network) and runs as root (Karabiner's HID sockets require it). On shared Macs, any local user in the `staff` group can send commands — see [Permissions](docs/permissions.md) to control which tools are exposed.

## Known Limitations

- **No clipboard paste** — iPhone Mirroring does not bridge the Mac clipboard when paste is triggered programmatically. All text must be typed character-by-character.
- **ISO keyboard section key** — On ISO keyboards (e.g., Canadian-CSA), characters tied to the section key (`§`, `±`) cannot be typed because macOS and iOS swap keycodes differently. These characters are silently skipped.
- **iOS autocorrect** — iOS applies autocorrect to typed text. Disable it in iPhone Settings > General > Keyboard, or type words followed by spaces to confirm them.
- **Single-user only** — The helper socket has no authentication. On shared Macs, any local user in the `staff` group can send commands.
- **No background interaction** — The iPhone Mirroring window must be visible. Closing it or locking the phone kills all input.

## Updating

```bash
# npx (always fetches latest)
npx -y iphone-mirroir-mcp install

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

## Documentation

| | |
|---|---|
| [Tools Reference](docs/tools.md) | All 18 tools, parameters, and input workflows |
| [Permissions](docs/permissions.md) | Fail-closed permission model and config file |
| [Architecture](docs/architecture.md) | System diagram and how input reaches the iPhone |
| [Troubleshooting](docs/troubleshooting.md) | Debug mode and common issues |

---

> **Why "mirroir"?** — It's the old French spelling of *miroir* (mirror). A nod to the author's roots, not a typo.
