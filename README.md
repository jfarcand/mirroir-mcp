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

Give your AI eyes, hands, and a real iPhone. An MCP server that lets any AI agent see the screen, tap what it needs, and figure the rest out — through macOS iPhone Mirroring. Experimental support for macOS windows. [32 tools](docs/tools.md), any MCP client.

## What's Changed

- **Icon detection (YOLO CoreML)** — `describe_screen` can now detect non-text UI elements (icons, buttons, toggles, activity rings) alongside Vision OCR text. Drop a CoreML `.mlmodelc` in `~/.mirroir-mcp/models/` and the server auto-detects it at startup. See [Icon Detection](#icon-detection) for details.
- **Startup config dump** — All effective configuration values are logged at startup in a grouped two-column format. Check `~/.mirroir-mcp/mirroir.log` to see exactly what settings are active.
- **Component calibration report** — All 18 iOS component definitions [tested against Apple Health (Santé)](https://gist.github.com/jfarcand/bb11f9c55814d134f47c814d0a5060d4). Scoring system correctly resolves conflicts between permissive and specific definitions. Zone-boundary absorption prevents cross-zone component merging.
- **Trackpad-style scroll** — Swipe gestures use continuous trackpad attributes (gesture phases, pixel deltas) for reliable scrolling in iPhone Mirroring.
- **Crash recovery** — `--restart-on-crash` flag re-execs the binary via `execv()` on SIGSEGV/SIGABRT/SIGBUS/SIGILL, preserving the MCP client connection.
- **Debug log preservation** — When `--debug` is active, logs survive server restarts instead of being truncated.
- **Component-driven exploration** — The explorer matches screen regions against [component definitions](docs/components.md) (`.md` files describing UI patterns like table rows, toggles, tab bars) instead of guessing from raw OCR. Multi-row elements (Health app summary cards) are absorbed into single tappable components. Calibrate definitions against live screens with `calibrate_component`.
- **Hot reload** — During development, the server detects when its binary is rebuilt and reloads via `execv()`, preserving the MCP client connection. No manual reconnect needed after `swift build`.
- **Autonomous app explorer** — `generate_skill` with `action: "explore"` does BFS graph traversal of any app, producing SKILL.md files automatically. Supports mobile, social, and desktop exploration strategies.
- **CGEvent-only input** — All input (tap, swipe, type, press_key, shake) uses macOS CGEvent API directly. No kernel extensions, no root privileges, no helper daemons.

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

The first time you take a screenshot, macOS will prompt for **Screen Recording** and **Accessibility** permissions. Grant both.

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

## How it works

Every interaction follows the same loop: **observe, reason, act**. `describe_screen` gives the AI every text element with tap coordinates (eyes). The LLM decides what to do next (brain). `tap`, `type_text`, `swipe` execute the action (hands) — then it loops back to observe. No scripts, no coordinates, just intent.

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

When you find yourself repeating the same agent workflow, capture it as a skill. Skills are SKILL.md files — numbered steps the AI follows, adapting to layout changes and unexpected dialogs. Steps like `Tap "Email"` use OCR — no hardcoded coordinates.

Place files in `~/.mirroir-mcp/skills/` (global) or `<cwd>/.mirroir-mcp/skills/` (project-local).

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

### Skill Marketplace

Install ready-to-use skills from [jfarcand/mirroir-skills](https://github.com/jfarcand/mirroir-skills):

```bash
git clone https://github.com/jfarcand/mirroir-skills ~/.mirroir-mcp/skills
```

## Test Runner

Run skills deterministically from the CLI — no AI in the loop. Designed for CI and regression testing.

```bash
mirroir test apps/settings/check-about
mirroir test --junit results.xml --verbose        # JUnit output
mirroir test --dry-run apps/settings/check-about    # validate without executing
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

Exit code `0` = all pass, `1` = any failure.

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
mirroir test --agent skill                          # deterministic OCR diagnosis
mirroir test --agent claude-sonnet-4-6 skill        # + AI via Anthropic
mirroir test --agent gpt-4o skill                   # + AI via OpenAI
mirroir test --agent ollama:llama3 skill             # + AI via local Ollama
```

Set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` for cloud models. Custom agent profiles go in `~/.mirroir-mcp/agents/`. All AI errors are non-fatal.

## Recorder

Record interactions as a skill file:

```bash
mirroir record -o login-flow.yaml -n "Login Flow" --app "MyApp"
```

## Generate Skill

Let an AI agent explore an app and produce SKILL.md files automatically:

```
Explore the Settings app and generate a skill that checks the iOS version.
```

Uses DFS graph traversal — tapping unvisited elements, backtracking when branches are exhausted. Duplicate screens are automatically skipped.

## Doctor

Verify your setup:

```bash
mirroir doctor
mirroir doctor --json    # machine-readable output
```

## Configure

Set up your keyboard layout for non-US keyboards:

```bash
mirroir configure
```

## Updating

```bash
# curl installer
/bin/bash -c "$(curl -fsSL https://mirroir.dev/get-mirroir.sh)"

# npx
npx -y mirroir-mcp install

# Homebrew
brew upgrade mirroir-mcp

# From source
git pull && swift build -c release
```

## Uninstall

```bash
# Homebrew
brew uninstall mirroir-mcp

# From source
./uninstall-mirroir.sh
```

## Icon Detection

By default, `describe_screen` uses Apple Vision OCR to detect text on screen. If a YOLO CoreML model (`.mlmodelc`) is present in `~/.mirroir-mcp/models/`, the server auto-detects it and merges icon detection results with OCR text — giving the AI tap targets for non-text elements like buttons, toggles, and tab bar icons that text-only OCR misses.

| Mode | `ocrBackend` setting | Behavior |
|------|---------------------|----------|
| Auto-detect (default) | `"auto"` | Uses Vision + YOLO if a model is installed, Vision only otherwise |
| Vision only | `"vision"` | Apple Vision OCR text only |
| YOLO only | `"yolo"` | CoreML element detection only |
| Both | `"both"` | Always merge both backends (fails gracefully to Vision if no model) |

### Installing a model

Place a compiled CoreML model (`.mlmodelc`) in `~/.mirroir-mcp/models/`. The server will find and load it automatically. You can also point to a specific path via the `yoloModelPath` setting or `MIRROIR_YOLO_MODEL_PATH` environment variable.

The `yoloConfidenceThreshold` setting (default: `0.3`) controls the minimum detection confidence — lower values detect more elements but may introduce noise.

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
| [Tools Reference](docs/tools.md) | All 32 tools, parameters, and input workflows |
| [FAQ](docs/faq.md) | Security, focus stealing, keyboard layouts |
| [Security](docs/security.md) | Threat model, kill switch, and recommendations |
| [Permissions](docs/permissions.md) | Fail-closed permission model and config file |
| [Known Limitations](docs/limitations.md) | Focus stealing, keyboard layout gaps, autocorrect |
| [Component Detection](docs/components.md) | Component definitions, calibration, and the detection pipeline |
| [Compiled Skills](docs/compiled-skills.md) | Zero-OCR skill replay |
| [Testing](docs/testing.md) | FakeMirroring, integration tests, and CI strategy |
| [Troubleshooting](docs/troubleshooting.md) | Debug mode and common issues |
| [Contributing](CONTRIBUTING.md) | How to add tools, commands, and tests |
| [Skills Marketplace](docs/skills-marketplace.md) | Skill format, plugin discovery, and authoring |

## Contributing

Contributions welcome. By submitting a patch, you agree to the [Contributor License Agreement](CLA.md) — your Git commit metadata serves as your electronic signature.

---

> **Why "mirroir"?** — It's the old French spelling of *miroir* (mirror). A nod to the author's roots, not a typo.
