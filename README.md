<p align="center">
  <img src="website/public/mirroir-wordmark.svg" alt="mirroir-mcp" width="128" />
</p>

# mirroir-mcp

[![npm version](https://img.shields.io/npm/v/mirroir-mcp)](https://www.npmjs.com/package/mirroir-mcp)
[![Build](https://github.com/jfarcand/mirroir-mcp/actions/workflows/build.yml/badge.svg)](https://github.com/jfarcand/mirroir-mcp/actions/workflows/build.yml)
[![Install](https://github.com/jfarcand/mirroir-mcp/actions/workflows/install.yml/badge.svg)](https://github.com/jfarcand/mirroir-mcp/actions/workflows/install.yml)
[![Installers](https://github.com/jfarcand/mirroir-mcp/actions/workflows/installers.yml/badge.svg)](https://github.com/jfarcand/mirroir-mcp/actions/workflows/installers.yml)
[![MCP Compliance](https://github.com/jfarcand/mirroir-mcp/actions/workflows/mcp-compliance.yml/badge.svg)](https://github.com/jfarcand/mirroir-mcp/actions/workflows/mcp-compliance.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](https://support.apple.com/en-us/105071)

An MCP server that controls iPhones through macOS iPhone Mirroring — and any macOS window. [Screenshot, tap, swipe, type, scroll_to, measure](docs/tools.md) from any MCP client.

## What's Changed

- **`generate_skill` tool** — AI agents can now explore an app and produce a ready-to-run SKILL.md autonomously. Session-based: `start` → navigate with tap/swipe → `capture` each screen → `finish` to emit the skill file.
- **`reset_app` carousel search** — `reset_app` now swipes through the App Switcher carousel to find off-screen app cards instead of giving up after one OCR scan.

## Requirements

- macOS 15+
- iPhone connected via [iPhone Mirroring](https://support.apple.com/en-us/105071)

## Install

```bash
/bin/bash -c "$(curl -fsSL https://mirroir.dev/get-mirroir.sh)"
```

or via [npx](https://www.npmjs.com/package/mirroir-mcp):

```bash
npx -y mirroir-mcp install
```

or via [Homebrew](https://tap.mirroir.dev):

```bash
brew tap jfarcand/tap && brew install mirroir-mcp
```

After install, approve the DriverKit system extension if prompted: **System Settings > General > Login Items & Extensions**. The first time you take a screenshot, macOS will prompt for **Screen Recording** and **Accessibility** permissions. Grant both.

<details>
<summary>Per-client setup</summary>

#### Claude Code

```bash
claude mcp add --transport stdio mirroir -- npx -y mirroir-mcp
```

#### GitHub Copilot (VS Code)

Install from the MCP server gallery: search `@mcp mirroir` in the Extensions view, or add to `.vscode/mcp.json`:

```json
{
  "servers": {
    "mirroir": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "mirroir-mcp"]
    }
  }
}
```

#### Cursor

Add to `.cursor/mcp.json` in your project root:

```json
{
  "mcpServers": {
    "mirroir": {
      "command": "npx",
      "args": ["-y", "mirroir-mcp"]
    }
  }
}
```

#### OpenAI Codex

```bash
codex mcp add mirroir -- npx -y mirroir-mcp
```

Or add to `~/.codex/config.toml`:

```toml
[mcp_servers.mirroir]
command = "npx"
args = ["-y", "mirroir-mcp"]
```

#### Helper daemon only

If your MCP client is already configured but the helper daemon isn't running:

```bash
npx mirroir-mcp setup
```

</details>

<details>
<summary>Install from source</summary>

```bash
git clone https://github.com/jfarcand/mirroir-mcp.git
cd mirroir-mcp
./mirroir.sh
```

Use the full path to the binary in your `.mcp.json`: `<repo>/.build/release/mirroir-mcp`.

</details>

## Examples

Paste any of these into Claude Code, Claude Desktop, ChatGPT, Cursor, or any MCP client:

```
Open Messages, find my conversation with Alice, and send "running 10 min late".
```

```
Open Calendar, create a new event called "Dentist" next Tuesday at 2pm.
```

```
Open my Expo Go app, tap "LoginDemo", test the login screen with
test@example.com / password123. Screenshot after each step.
```

```
Start recording, open Settings, scroll to General > About, stop recording.
```

## Skills

Skills are multi-step automation flows. Steps like `tap: "Email"` use OCR — no hardcoded coordinates.

Two formats: **SKILL.md** (recommended) and **YAML**. Place files in `~/.mirroir-mcp/skills/` (global) or `<cwd>/.mirroir-mcp/skills/` (project-local).

```markdown
---
version: 1
name: Commute ETA Notification
app: Waze, Messages
tags: ["workflow", "cross-app"]
---

## Steps

1. Launch **Waze**
2. Wait for "Où va-t-on ?" to appear
3. Tap "Où va-t-on ?"
4. Wait for "${DESTINATION:-Travail}" to appear
5. Tap "${DESTINATION:-Travail}"
6. Wait for "Y aller" to appear
7. Tap "Y aller"
8. Wait for "min" to appear
9. Remember: Read the commute time and ETA.
10. Press Home
11. Launch **Messages**
12. Tap "New Message"
13. Type "${RECIPIENT}" and select the contact
14. Type "On my way! ETA {eta}"
15. Press **Return**
16. Screenshot: "message_sent"
```

`${VAR}` placeholders resolve from environment variables. `${VAR:-default}` for fallbacks.

<details>
<summary>Equivalent YAML format</summary>

```yaml
name: Commute ETA Notification
app: Waze, Messages

steps:
  - launch: "Waze"
  - wait_for: "Où va-t-on ?"
  - tap: "Où va-t-on ?"
  - wait_for: "${DESTINATION:-Travail}"
  - tap: "${DESTINATION:-Travail}"
  - wait_for: "Y aller"
  - tap: "Y aller"
  - wait_for: "min"
  - remember: "Read the commute time and ETA."
  - press_home: true
  - launch: "Messages"
  - tap: "New Message"
  - type: "${RECIPIENT}"
  - tap: "${RECIPIENT}"
  - type: "On my way! ETA {eta}"
  - press_key: "return"
  - screenshot: "message_sent"
```

</details>

### Skill Marketplace

Install ready-to-use skills from [jfarcand/mirroir-skills](https://github.com/jfarcand/mirroir-skills):

```bash
git clone https://github.com/jfarcand/mirroir-skills ~/.mirroir-mcp/skills
```

### Migrate YAML to SKILL.md

```bash
mirroir migrate skill.yaml                    # single file
mirroir migrate --dir ~/.mirroir-mcp/skills   # entire directory
```

## Test Runner

Run skills deterministically from the CLI — no AI in the loop. Designed for CI and regression testing.

```bash
mirroir test apps/settings/check-about
mirroir test --junit results.xml --verbose        # JUnit output
mirroir test --dry-run apps/settings/*.yaml        # validate without executing
```

| Option | Description |
|---|---|
| `--junit <path>` | Write JUnit XML report |
| `--screenshot-dir <dir>` | Save failure screenshots (default: `./mirroir-test-results/`) |
| `--timeout <seconds>` | `wait_for` timeout (default: 15) |
| `--verbose` | Step-by-step detail |
| `--dry-run` | Parse and validate without executing |
| `--no-compiled` | Skip compiled skills, force full OCR |
| `--agent [model]` | Diagnose failures (see [Agent Diagnosis](#agent-diagnosis)) |

The test runner executes YAML skills only. Exit code `0` = all pass, `1` = any failure.

### Compiled Skills

Compile a skill once to capture coordinates and timing. Replay with zero OCR.

```bash
mirroir compile apps/settings/check-about        # compile
mirroir test apps/settings/check-about            # auto-detects .compiled.json
mirroir test --no-compiled check-about            # force full OCR
```

AI agents auto-compile skills as a side-effect of the first MCP run. See [Compiled Skills](docs/compiled-skills.md) for details.

### Agent Diagnosis

When a compiled skill fails, `--agent` diagnoses *why* and suggests fixes.

```bash
mirroir test --agent skill.yaml                    # deterministic OCR diagnosis
mirroir test --agent claude-sonnet-4-6 skill.yaml  # + AI via Anthropic
mirroir test --agent gpt-4o skill.yaml             # + AI via OpenAI
mirroir test --agent ollama:llama3 skill.yaml      # + AI via local Ollama
```

Set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` for cloud models. Custom agent profiles go in `~/.mirroir-mcp/agents/`. All AI errors are non-fatal.

## Recorder

Record interactions with the mirrored iPhone as a skill YAML file.

```bash
mirroir record -o login-flow.yaml -n "Login Flow" --app "MyApp"
mirroir record --no-ocr -o quick-capture.yaml      # skip OCR (faster)
```

Press Ctrl+C to stop and save. Review the output and add `wait_for` steps where needed.

## Generate Skill

Let an AI agent explore an app and write the skill for you. The `generate_skill` MCP tool uses a three-phase session:

1. **Start** — launches the app, OCRs the first screen
2. **Navigate + Capture** — the agent taps, swipes, types to explore; calls `capture` after each navigation to record the screen
3. **Finish** — assembles all captured screens into a SKILL.md with steps, landmarks, and metadata

```
Explore the Settings app and generate a skill that checks the iOS version.
```

The agent drives the exploration autonomously — duplicate screens are automatically skipped, and the generated skill uses OCR-based landmarks (no hardcoded coordinates).

## Doctor

Verify your setup:

```bash
mirroir doctor
mirroir doctor --json    # machine-readable output
```

## Updating

```bash
# curl installer
/bin/bash -c "$(curl -fsSL https://mirroir.dev/get-mirroir.sh)"

# npx
npx -y mirroir-mcp install

# Homebrew
brew upgrade mirroir-mcp
sudo brew services restart mirroir-mcp

# From source
git pull
sudo ./scripts/reinstall-helper.sh
```

## Uninstall

```bash
# Homebrew
sudo brew services stop mirroir-mcp
brew uninstall mirroir-mcp

# From source
./uninstall-mirroir.sh
```

## Configuration

Override timing defaults via `settings.json`:

```json
// .mirroir-mcp/settings.json (project-local) or ~/.mirroir-mcp/settings.json (global)
{
  "keystrokeDelayUs": 20000,
  "clickHoldUs": 100000
}
```

Environment variables also work: `MIRROIR_KEYSTROKE_DELAY_US`. See [`TimingConstants.swift`](Sources/HelperLib/TimingConstants.swift) for all keys.

## Documentation

| | |
|---|---|
| [Tools Reference](docs/tools.md) | All 31 tools, parameters, and input workflows |
| [FAQ](docs/faq.md) | Security, focus stealing, DriverKit, keyboard layouts |
| [Security](docs/security.md) | Threat model, kill switch, and recommendations |
| [Permissions](docs/permissions.md) | Fail-closed permission model and config file |
| [Architecture](docs/architecture.md) | System diagram and how input reaches the iPhone |
| [Known Limitations](docs/limitations.md) | Focus stealing, keyboard layout gaps, autocorrect |
| [Compiled Skills](docs/compiled-skills.md) | Zero-OCR skill replay |
| [Testing](docs/testing.md) | FakeMirroring, integration tests, and CI strategy |
| [Troubleshooting](docs/troubleshooting.md) | Debug mode and common issues |
| [Contributing](CONTRIBUTING.md) | How to add tools, commands, and tests |
| [Skills Marketplace](docs/skills-marketplace.md) | Skill format, plugin discovery, and authoring |

## Contributing

Contributions welcome. By submitting a patch, you agree to the [Contributor License Agreement](CLA.md) — your Git commit metadata serves as your electronic signature.

---

> **Why "mirroir"?** — It's the old French spelling of *miroir* (mirror). A nod to the author's roots, not a typo.
