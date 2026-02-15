# Scenarios & Marketplace

Scenarios are YAML files that describe multi-step iPhone automation flows as intents, not scripts. The MCP server provides the tools; scenarios teach the AI what to do with them.

## Overview

The system has two layers:

1. **This repository** (`iphone-mirroir-mcp`) — provides 22 MCP tools for iPhone interaction
2. **Scenario repositories** (e.g., [jfarcand/iphone-mirroir-scenarios](https://github.com/jfarcand/iphone-mirroir-scenarios)) — provide reusable YAML scenario files + plugin discovery

Scenarios are intentionally simple. Steps like `tap: "Email"` don't specify pixel coordinates — the AI uses `describe_screen` for fuzzy OCR matching and adapts to unexpected dialogs, layout changes, and timing differences.

## Plugin Discovery

Scenarios can be installed via AI coding assistant plugin systems or manually.

### Claude Code

```bash
claude plugin marketplace add jfarcand/iphone-mirroir-scenarios
claude plugin install scenarios@iphone-mirroir-scenarios
```

Plugin metadata lives in `.claude-plugin/marketplace.json` in the scenario repository. The `SKILL.md` file in the scenario repo teaches Claude how to interpret scenario steps.

### GitHub Copilot CLI

```bash
copilot plugin marketplace add jfarcand/iphone-mirroir-scenarios
copilot plugin install scenarios@iphone-mirroir-scenarios
```

Plugin metadata lives in `.github/plugin/marketplace.json` in the scenario repository.

### Manual Installation

Clone or copy scenario YAML files into one of the scan directories:

```bash
# Global — available in all projects
git clone https://github.com/jfarcand/iphone-mirroir-scenarios.git \
    ~/.iphone-mirroir-mcp/scenarios/

# Project-local — available only in current project
mkdir -p .iphone-mirroir-mcp/scenarios/
cp my-scenario.yaml .iphone-mirroir-mcp/scenarios/
```

Project-local scenarios with the same filename override global ones.

## Scenario YAML Format

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Human-readable scenario name |
| `app` | string | Target app(s), comma-separated for cross-app flows |
| `description` | string | What the scenario does |
| `steps` | list | Ordered list of step objects |

### Optional Metadata

| Field | Type | Description |
|-------|------|-------------|
| `ios_min` | string | Minimum iOS version (e.g., `"17.0"`) |
| `locale` | string | Expected device locale (e.g., `"fr-CA"`) |
| `tags` | list | Categorization tags (e.g., `["productivity", "messaging"]`) |

### Example

```yaml
name: Send Slack Message
app: Slack
description: Send a direct message to a contact in Slack

steps:
  - launch: "Slack"
  - wait_for: "Home"
  - tap: "Direct Messages"
  - wait_for: "${RECIPIENT}"
  - tap: "${RECIPIENT}"
  - wait_for: "Message"
  - tap: "Message"
  - type: "${MESSAGE:-Hey, just checking in!}"
  - press_key: "return"
  - screenshot: "message_sent"
```

## Step Types

Each step is a single key-value pair in the `steps` list. The AI interprets each step using the appropriate MCP tool.

| Step Type | Value | MCP Tool Used | Description |
|-----------|-------|---------------|-------------|
| `launch` | App name (string) | `launch_app` | Open an app via Spotlight search |
| `tap` | Element text (string) | `describe_screen` + `tap` | Find element by OCR text match, tap its coordinates |
| `type` | Text to type (string) | `type_text` | Type text into the currently focused field |
| `press_key` | Key name (string) | `press_key` | Press a special key (return, escape, tab, etc.) |
| `swipe` | Direction (string) | `swipe` | Swipe in a direction (up, down, left, right) |
| `wait_for` | Element text (string) | `describe_screen` (poll) | Wait until text appears on screen (retry with describe_screen) |
| `assert_visible` | Element text (string) | `describe_screen` | Verify text is visible; fail the scenario if not found |
| `screenshot` | Label (string) | `screenshot` | Capture a screenshot with a descriptive label |
| `shake` | `true` | `shake` | Trigger a shake gesture (debug menus, undo) |
| `press_home` | `true` | `press_home` | Return to the home screen |
| `remember` | Instruction (string) | _(AI-interpreted)_ | Tell the AI to extract and remember data from the current screen |
| `long_press` | Element text (string) | `describe_screen` + `long_press` | Find element by OCR, long press on it |
| `drag` | Object with `from`/`to` | `describe_screen` + `drag` | Find elements by OCR, drag between them |
| `condition` | Object with `if_visible`/`if_not_visible` + `then`/`else` | `describe_screen` | Branch based on screen state — see below |

### Conditions

Scenarios can branch using `condition` steps. The AI calls `describe_screen` to evaluate the condition, then executes the matching branch:

```yaml
- condition:
    if_visible: "Unread"        # or if_not_visible
    then:
      - tap: "Unread"
      - tap: "Archive"
    else:                       # optional
      - screenshot: "empty"
```

If the condition is true, the `then` steps execute. If false and `else` is present, those steps execute instead. Steps inside branches are regular steps, including nested conditions (up to 3 levels deep).

## Variable Substitution

### Environment Variables: `${VAR}`

Variables wrapped in `${...}` are resolved from environment variables at `get_scenario` time (before the AI sees the YAML).

```yaml
- type: "${TEST_EMAIL}"           # Required — left as ${TEST_EMAIL} if unset
- type: "${CITY:-Montreal}"       # Optional — defaults to "Montreal" if unset
```

| Syntax | Behavior |
|--------|----------|
| `${VAR}` | Substituted with env var value. Left as-is if unset (AI flags it as missing). |
| `${VAR:-default}` | Substituted with env var value. Uses `default` if env var is unset. |

### AI-Remembered Data: `{var}`

Single-brace variables are placeholders for data the AI extracts during scenario execution via `remember:` steps:

```yaml
- remember: "Read the commute time and ETA from the navigation screen."
# AI extracts: commute_time = "35 min", eta = "9:15 AM"

- type: "On my way! {commute_time} to the office (ETA {eta})"
# AI substitutes: "On my way! 35 min to the office (ETA 9:15 AM)"
```

These are never resolved by the server — they exist in the YAML for the AI to interpret contextually.

## AI Execution Model

Scenarios are executed by AI, not by a deterministic runner. This is by design:

**Why AI instead of a script runner:**
- **Fuzzy matching:** `tap: "Email"` works even if the actual text is "Email Address" or "E-mail"
- **Scroll discovery:** If an element isn't visible, the AI knows to scroll down and re-scan
- **Dialog dismissal:** Unexpected permission dialogs, update prompts, or alerts are handled naturally
- **Retry logic:** Network timeouts, slow animations, and loading states are handled contextually
- **Layout adaptation:** Different iPhone models, font sizes, and orientations are handled without pixel-perfect coordinates

**The remember/recall pattern:**
1. A `remember:` step tells the AI to extract specific data from the current screen
2. The AI uses `describe_screen` to read the screen content
3. The AI stores the extracted values internally
4. Later `{variable}` references in `type:` steps use those stored values

This enables cross-app data flows — read data from one app, switch apps, then use that data in another.

## Scenario Validation

Scenario YAML files should be validated for:

- **Required fields:** `name`, `app`, `description`, `steps` must all be present
- **Step types:** Each step key must be a recognized step type
- **Variable syntax:** `${VAR}` patterns must have valid identifier names
- **Non-empty steps:** The `steps` list must contain at least one step

## Available Scenarios

Scenarios are maintained in the [iphone-mirroir-scenarios](https://github.com/jfarcand/iphone-mirroir-scenarios) repository. Install them via the plugin system (see [Plugin Discovery](#plugin-discovery) above) or clone manually into `~/.iphone-mirroir-mcp/scenarios/`.

## Contributing a Scenario

Checklist for adding a new scenario:

1. **Create the YAML file** in the appropriate directory under `scenarios/`
   - `apps/<app-name>/` for app-specific scenarios
   - `testing/<framework>/` for test automation scenarios

2. **Include all required fields:** `name`, `app`, `description`, `steps`

3. **Use environment variables** for user-specific data (`${RECIPIENT}`, `${MESSAGE}`)

4. **Provide defaults** for optional parameters (`${CITY:-Montreal}`)

5. **Add verification steps:**
   - `wait_for:` after navigation to confirm the expected screen loaded
   - `assert_visible:` to verify the action succeeded
   - `screenshot:` at key points for visual confirmation

6. **Test the scenario** end-to-end on a real device with `get_scenario` + manual execution

7. **Keep steps intent-based** — describe *what* to do, not *how* to do it. Let the AI handle coordinates, scrolling, and timing.
