<p align="center">
  <img src="website/public/logo-robot.svg" alt="iphone-mirroir-mcp" width="120" />
</p>

# iphone-mirroir-mcp

[![npm version](https://img.shields.io/npm/v/iphone-mirroir-mcp)](https://www.npmjs.com/package/iphone-mirroir-mcp)
[![Build](https://github.com/jfarcand/iphone-mirroir-mcp/actions/workflows/build.yml/badge.svg)](https://github.com/jfarcand/iphone-mirroir-mcp/actions/workflows/build.yml)
[![Install](https://github.com/jfarcand/iphone-mirroir-mcp/actions/workflows/install.yml/badge.svg)](https://github.com/jfarcand/iphone-mirroir-mcp/actions/workflows/install.yml)
[![MCP Compliance](https://github.com/jfarcand/iphone-mirroir-mcp/actions/workflows/mcp-compliance.yml/badge.svg)](https://github.com/jfarcand/iphone-mirroir-mcp/actions/workflows/mcp-compliance.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](https://support.apple.com/en-us/105071)

MCP server that controls a real iPhone through macOS iPhone Mirroring. [Screenshot, tap, swipe, type](docs/tools.md) — from any MCP client. Works with any app on screen, no source code required.

Input flows through [Karabiner](https://karabiner-elements.pqrs.org/) DriverKit virtual HID devices because iPhone Mirroring blocks standard CGEvent injection.

## Requirements

- macOS 15+
- iPhone connected via [iPhone Mirroring](https://support.apple.com/en-us/105071)

## Install

```bash
/bin/bash -c "$(curl -fsSL https://mirroir.dev/get-mirroir.sh)"
```

Clones the repo, builds from source, installs the helper daemon, and configures Karabiner. Override the install location with `IPHONE_MIRROIR_HOME`.

After install, approve the DriverKit extension if prompted: **System Settings > General > Login Items & Extensions** — enable all toggles under Karabiner-Elements. The first time you take a screenshot, macOS will prompt for **Screen Recording** and **Accessibility** permissions. Grant both.

<details>
<summary>npx (alternative)</summary>

```bash
npx -y iphone-mirroir-mcp install
```

The npx installer prompts you to select your MCP client (Claude Code, Claude Desktop, ChatGPT, Cursor, GitHub Copilot, or OpenAI Codex) and writes the config automatically.

</details>

<details>
<summary>Per-client setup</summary>

#### Claude Code

```bash
claude mcp add --transport stdio iphone-mirroring -- npx -y iphone-mirroir-mcp
```

#### GitHub Copilot (VS Code)

Install from the MCP server gallery: search `@mcp iphone-mirroring` in the Extensions view, or add to `.vscode/mcp.json`:

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
./mirroir.sh
```

The installer handles everything: installs Karabiner if missing (with confirmation), waits for the DriverKit extension approval, builds both binaries, configures the Karabiner ignore rule, installs the helper daemon, and runs a verification check. Use the full path to the binary in your `.mcp.json`: `<repo>/.build/release/iphone-mirroir-mcp`.

</details>

## Examples

Paste any of these into Claude Code, Claude Desktop, ChatGPT, Cursor, or any MCP client:

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

## Scenarios

Scenarios are YAML files that describe multi-step automation flows as intents, not scripts. Steps like `tap: "Email"` don't specify coordinates — the AI finds the element by fuzzy OCR matching and adapts to unexpected dialogs, screen layout changes, and timing.

**Cross-app workflow** — get your commute ETA from Waze, then text it to someone via iMessage:

```yaml
name: Commute ETA Notification
app: Waze, Messages
description: Get commute ETA from Waze, then send it via iMessage.

steps:
  - launch: "Waze"
  - wait_for: "Où va-t-on ?"
  - tap: "Où va-t-on ?"
  - wait_for: "${DESTINATION:-Travail}"
  - tap: "${DESTINATION:-Travail}"
  - wait_for: "Y aller"
  - tap: "Y aller"
  - wait_for: "min"
  - remember: "Read the commute time and ETA from the navigation screen."
  - press_home: true
  - launch: "Messages"
  - wait_for: "Messages"
  - tap: "New Message"
  - wait_for: "À :"
  - tap: "À :"
  - type: "${RECIPIENT}"
  - wait_for: "${RECIPIENT}"
  - tap: "${RECIPIENT}"
  - wait_for: "iMessage"
  - tap: "iMessage"
  - type: "${MESSAGE_PREFIX:-On my way!} {commute_time} to the office (ETA {eta})"
  - press_key: "return"
  - wait_for: "Distribué"
  - screenshot: "message_sent"
```

`${VAR}` placeholders are resolved from environment variables. Use `${VAR:-default}` for fallback values. Place scenarios in `~/.iphone-mirroir-mcp/scenarios/` (global) or `<cwd>/.iphone-mirroir-mcp/scenarios/` (project-local). Both directories are scanned recursively.

### Scenario Marketplace

Ready-to-use scenarios that automate anything a human can do on an iPhone — tap, type, navigate, chain apps together. If you can do it manually, you can script it. Install from [jfarcand/iphone-mirroir-scenarios](https://github.com/jfarcand/iphone-mirroir-scenarios):

#### Claude Code

```bash
claude plugin marketplace add jfarcand/iphone-mirroir-scenarios
claude plugin install scenarios@iphone-mirroir-scenarios
```

#### GitHub Copilot CLI

```bash
copilot plugin marketplace add jfarcand/iphone-mirroir-scenarios
copilot plugin install scenarios@iphone-mirroir-scenarios
```

#### Manual (all other clients)

```bash
git clone https://github.com/jfarcand/iphone-mirroir-scenarios ~/.iphone-mirroir-mcp/scenarios
```

Once installed, scenarios are available through the `list_scenarios` and `get_scenario` tools. Claude Code and Copilot CLI load the [SKILL.md](https://github.com/jfarcand/iphone-mirroir-scenarios/blob/main/plugins/scenarios/skills/scenarios/SKILL.md) automatically, which teaches the AI how to interpret and execute each step type. For other clients, ask the AI to call `list_scenarios` and then execute the steps.

See [Tools Reference](docs/tools.md#scenarios) for the full step type reference and directory layout.

## Updating

```bash
# curl installer (re-run — pulls latest and rebuilds)
/bin/bash -c "$(curl -fsSL https://mirroir.dev/get-mirroir.sh)"

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
./uninstall-mirroir.sh
```

## Documentation

| | |
|---|---|
| [Tools Reference](docs/tools.md) | All 22 tools, parameters, and input workflows |
| [FAQ](docs/faq.md) | Security, focus stealing, Karabiner, keyboard layouts |
| [Security](docs/security.md) | Threat model, kill switch, and recommendations |
| [Permissions](docs/permissions.md) | Fail-closed permission model and config file |
| [Architecture](docs/architecture.md) | System diagram and how input reaches the iPhone |
| [Known Limitations](docs/limitations.md) | Focus stealing, keyboard layout gaps, autocorrect |
| [Troubleshooting](docs/troubleshooting.md) | Debug mode and common issues |
| [Contributing](CONTRIBUTING.md) | How to add tools, commands, and tests |
| [Scenarios Marketplace](docs/scenarios-marketplace.md) | Scenario format, plugin discovery, and authoring |
| [Contributor License Agreement](CLA.md) | CLA for all contributions |

## Contributing

Contributions are welcome! By submitting a pull request or patch, you agree to the [Contributor License Agreement](CLA.md). Your Git commit metadata (name and email) serves as your electronic signature — no separate form to sign.

The CLA ensures the project can be maintained long-term under a consistent license. You retain full ownership of your contributions — the CLA simply grants the maintainer the right to distribute them as part of the project. Key provisions:

| Clause | Purpose |
|---|---|
| Copyright license (§2) | Grants a broad license so the project can be relicensed if needed (e.g., dual licensing for sustainability) |
| Patent license (§3) | Protects all users from patent claims by contributors (standard Apache-style) |
| Original work (§4) | Contributors certify they own what they submit |
| Employer clause (§6) | Covers the common case where a contributor's employer might claim ownership |
| Git-based signing (§7) | Submitting a PR = agreement — zero friction, similar to the DCO used by the Linux kernel |

---

> **Why "mirroir"?** — It's the old French spelling of *miroir* (mirror). A nod to the author's roots, not a typo.
