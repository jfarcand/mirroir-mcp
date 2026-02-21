# Tools Reference

All 26 tools exposed by the MCP server. Mutating tools require [permission](permissions.md) to appear in `tools/list`.

## Tool List

| Tool | Parameters | Description |
|------|-----------|-------------|
| `screenshot` | — | Capture the iPhone screen as base64 PNG |
| `describe_screen` | `skip_ocr`? | OCR the screen and return text elements with tap coordinates plus a grid-overlaid screenshot |
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
| `scroll_to` | `label`, `direction`?, `max_scrolls`? | Scroll until a text element becomes visible via OCR |
| `reset_app` | `name` | Force-quit an app via the App Switcher |
| `measure` | `action`, `until`, `max_seconds`?, `name`? | Time a screen transition after an action |
| `set_network` | `mode` | Toggle network settings (airplane, Wi-Fi, cellular) via Settings |
| `get_orientation` | — | Report portrait/landscape and window dimensions |
| `status` | — | Connection state, window geometry, and device readiness |
| `check_health` | — | Comprehensive setup diagnostic: mirroring, helper, DriverKit, screen capture |
| `list_scenarios` | — | List available scenarios (SKILL.md and YAML) from project-local and global config dirs |
| `get_scenario` | `name` | Read a scenario file (SKILL.md or YAML) with ${VAR} env substitution |

## Coordinates

Coordinates are in points relative to the mirroring window's top-left corner. Use `describe_screen` to get exact tap coordinates via OCR — its grid overlay also helps target unlabeled icons (back arrows, stars, gears) that OCR can't detect. For raw screenshots, coordinates are Retina 2x — divide pixel coordinates by 2 to get tap coordinates.

## Describe Screen

`describe_screen` runs Apple Vision OCR on the mirroring window and returns detected text elements with their tap coordinates, plus a grid-overlaid screenshot for visual context.

Set `skip_ocr: true` to skip Vision OCR and return only the grid-overlaid screenshot. This lets MCP clients use their own vision model to analyze the screen instead of relying on the built-in OCR (costs more tokens but can identify icons, images, and UI elements that text-only OCR misses).

## Typing Workflow

`type_text` and `press_key` route keyboard input through the Karabiner virtual HID keyboard via the helper daemon. If iPhone Mirroring isn't already frontmost, the MCP server activates it once (which may trigger a macOS Space switch) and stays there. Subsequent keyboard tool calls reuse the active window without switching again.

- Characters are mapped to USB HID keycodes with automatic keyboard layout translation — non-US layouts (French AZERTY, German QWERTZ, etc.) are supported via UCKeyTranslate
- iOS autocorrect applies — type carefully or disable it on the iPhone

## Key Press Workflow

`press_key` sends special keys that `type_text` can't handle — navigation keys, Return to submit forms, Escape to dismiss dialogs, Tab to switch fields, arrows to move through lists. Add modifiers for shortcuts like Cmd+N (new message) or Cmd+Z (undo).

For navigating within apps, combine `spotlight` + `type_text` + `press_key`. For example: `spotlight` → `type_text "Messages"` → `press_key return` → `press_key {"key":"n","modifiers":["command"]}` to open a new conversation.

## Scroll To

`scroll_to` scrolls in a direction until a target text element becomes visible via OCR. It checks if the element is already on screen before scrolling, and detects scroll exhaustion (when the screen content stops changing, meaning the list has reached its end).

- `label` (required): Text to find on screen
- `direction` (default: "up"): Scroll direction — "up" means swipe up (scroll content down), matching iOS convention
- `max_scrolls` (default: 10): Maximum scroll attempts before giving up

## Reset App

`reset_app` force-quits an app via the iOS App Switcher. Opens the App Switcher, finds the app card by OCR, swipes it up to dismiss, then returns to the home screen. If the app isn't in the switcher, it's treated as already quit (success). Use before `launch_app` to ensure a fresh app state.

## Measure

`measure` times a screen transition: performs an action, then polls OCR until a target label appears. Reports the measured duration and optionally fails if it exceeds a threshold.

- `action` (required): Action string in `type:value` format — `tap:Label`, `launch:AppName`, or `press_key:return`
- `until` (required): Text label to wait for after the action
- `max_seconds` (optional): Maximum allowed seconds — fails if exceeded
- `name` (optional): Name for reporting (default: "measure")

## Set Network

`set_network` toggles network settings on the iPhone by navigating the Settings app. After toggling, it returns to the home screen.

Supported modes: `airplane_on`, `airplane_off`, `wifi_on`, `wifi_off`, `cellular_on`, `cellular_off`.

This is the most environment-dependent tool — it relies on the Settings app UI layout, which varies by locale and iOS version. `ElementMatcher` substring matching provides some resilience across locales.

## Scenarios

Scenarios are files that describe multi-step test flows as intents, not scripts. They can be written in **SKILL.md** format (YAML front matter + markdown body — the recommended format) or **YAML** format (legacy). The server provides two readonly tools for scenario discovery and reading — the AI is the execution engine that interprets steps and calls existing MCP tools.

### Why AI Execution?

Steps like `tap: "Email"` don't specify coordinates — the AI calls `describe_screen`, finds the element by fuzzy matching, and taps it. This matters because real iOS apps change between versions, vary across screen sizes, and throw unexpected UI (permission prompts, keyboard suggestions, notification banners). A deterministic script runner would need exact strings and hardcoded timeouts. The AI adapts: it scrolls to find off-screen elements, dismisses unexpected dialogs, retries failed steps, and flags unresolved `${VAR}` placeholders. Scenarios declare *what* should happen; the AI figures out *how*.

### Directory Layout

```
~/.mirroir-mcp/scenarios/          # global scenarios
<cwd>/.mirroir-mcp/scenarios/      # project-local (overrides global)
```

Both directories are scanned recursively, so you can organize scenarios into subdirectories (e.g. `apps/slack/send-message.md`). Project-local scenarios with the same relative path override global ones. When both a `.md` and `.yaml` file exist with the same stem name, the `.md` file takes precedence.

### SKILL.md Format (Recommended)

SKILL.md uses YAML front matter for metadata and a markdown body with natural-language steps. This is what AI agents natively understand — no YAML step syntax to learn.

```markdown
---
version: 1
name: Login Flow
app: Expo Go
tags: ["auth", "login"]
---

Test the login screen with valid credentials.

## Steps

1. Launch **Expo Go**
2. Wait for "Email" to appear
3. Tap "Email"
4. Type "${TEST_EMAIL}"
5. Tap "Sign In"
6. Verify "Welcome" is visible
7. Screenshot: "final_state"
```

Convert existing YAML scenarios with `mirroir migrate`:

```bash
mirroir migrate scenario.yaml              # convert a single file
mirroir migrate --dir path/to/scenarios/   # convert all YAML files in a directory
mirroir migrate --dry-run scenario.yaml    # preview without writing
```

### YAML Format (Legacy)

```yaml
name: Login Flow
app: Expo Go
description: Test the login screen with valid credentials

steps:
  - launch: "Expo Go"
  - wait_for: "Email"
  - tap: "Email"
  - type: "${TEST_EMAIL}"
  - tap: "Sign In"
  - assert_visible: "Welcome"
  - screenshot: "final_state"
```

### Variable Substitution

`${VAR}` placeholders are resolved from environment variables when `get_scenario` reads the file (both SKILL.md and YAML formats). Use `${VAR:-default}` to provide a fallback value when the variable is unset. Unresolved variables without defaults are left as-is so the AI can flag them.

```yaml
- type: "${RECIPIENT:-Phil Tremblay}"   # uses env var, falls back to "Phil Tremblay"
- type: "${API_KEY}"                     # left as-is if unset (AI will flag it)
```

### Step Types

Steps are intents — the AI maps each to the appropriate MCP tool calls:

| Step | AI Action |
|------|-----------|
| `launch` | calls `launch_app` |
| `tap: "Label"` | calls `describe_screen` to find element, then `tap` |
| `type` | calls `type_text` |
| `swipe: "up"` | calls `swipe` with appropriate coordinates |
| `wait_for: "Label"` | polls `describe_screen` until element appears |
| `assert_visible` / `assert_not_visible` | checks via `describe_screen` |
| `screenshot: "label"` | captures and labels in report |
| `press_key` | calls `press_key` |
| `press_home` | calls `press_home` to return to home screen |
| `open_url` | calls `open_url` |
| `shake` | calls `shake` |
| `scroll_to: "Label"` | calls `scroll_to` — scrolls until element visible |
| `reset_app: "AppName"` | calls `reset_app` — force-quit via App Switcher |
| `set_network: "mode"` | calls `set_network` — toggle airplane/wifi/cellular |
| `measure: { action, until, max }` | calls `measure` — time screen transitions |
| `remember: "instruction"` | AI reads dynamic data from screen and holds it for later steps |
| `condition:` | Branch based on screen state — see below |
| `repeat:` | Loop over steps until a screen condition is met — see below |

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

If the condition is true, the `then` steps execute. If false and `else` is present, those steps execute instead. Steps inside branches are regular steps, including nested conditions.

### Repeats

Scenarios can loop using `repeat` steps. The AI checks a screen condition before each iteration and stops when the condition fails or `max` is reached:

```yaml
- repeat:
    while_visible: "Unread"     # or until_visible, or times: N
    max: 10                      # required safety bound
    steps:
      - tap: "Unread"
      - tap: "Archive"
      - tap: "< Back"
```

Loop modes: `while_visible: "Label"` (continue while present), `until_visible: "Label"` (continue until appears), `times: N` (fixed count). Steps inside are regular steps, including conditions and nested repeats.
