# Tools Reference

All 22 tools exposed by the MCP server. Mutating tools require [permission](permissions.md) to appear in `tools/list`.

## Tool List

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
| `check_health` | — | Comprehensive setup diagnostic: mirroring, helper, Karabiner, screen capture |
| `list_scenarios` | — | List available YAML scenarios from project-local and global config dirs |
| `get_scenario` | `name` | Read a scenario YAML file with ${VAR} env substitution |

## Coordinates

Coordinates are in points relative to the mirroring window's top-left corner. Use `describe_screen` to get exact tap coordinates via OCR — its grid overlay also helps target unlabeled icons (back arrows, stars, gears) that OCR can't detect. For raw screenshots, coordinates are Retina 2x — divide pixel coordinates by 2 to get tap coordinates.

## Typing Workflow

`type_text` and `press_key` route keyboard input through the Karabiner virtual HID keyboard via the helper daemon. If iPhone Mirroring isn't already frontmost, the MCP server activates it once (which may trigger a macOS Space switch) and stays there. Subsequent keyboard tool calls reuse the active window without switching again.

- Characters are mapped to USB HID keycodes with automatic keyboard layout translation — non-US layouts (French AZERTY, German QWERTZ, etc.) are supported via UCKeyTranslate
- iOS autocorrect applies — type carefully or disable it on the iPhone

## Key Press Workflow

`press_key` sends special keys that `type_text` can't handle — navigation keys, Return to submit forms, Escape to dismiss dialogs, Tab to switch fields, arrows to move through lists. Add modifiers for shortcuts like Cmd+N (new message) or Cmd+Z (undo).

For navigating within apps, combine `spotlight` + `type_text` + `press_key`. For example: `spotlight` → `type_text "Messages"` → `press_key return` → `press_key {"key":"n","modifiers":["command"]}` to open a new conversation.

## Scenarios

Scenarios are YAML files that describe multi-step test flows as intents, not scripts. The server provides two readonly tools for scenario discovery and reading — the AI is the execution engine that interprets steps and calls existing MCP tools.

### Why AI Execution?

Steps like `tap: "Email"` don't specify coordinates — the AI calls `describe_screen`, finds the element by fuzzy matching, and taps it. This matters because real iOS apps change between versions, vary across screen sizes, and throw unexpected UI (permission prompts, keyboard suggestions, notification banners). A deterministic script runner would need exact strings and hardcoded timeouts. The AI adapts: it scrolls to find off-screen elements, dismisses unexpected dialogs, retries failed steps, and flags unresolved `${VAR}` placeholders. Scenarios declare *what* should happen; the AI figures out *how*.

### Directory Layout

```
~/.iphone-mirroir-mcp/scenarios/          # global scenarios
<cwd>/.iphone-mirroir-mcp/scenarios/      # project-local (overrides global)
```

Both directories are scanned recursively, so you can organize scenarios into subdirectories (e.g. `apps/slack/send-message.yaml`). Project-local scenarios with the same relative path override global ones.

### YAML Format

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

`${VAR}` placeholders are resolved from environment variables when `get_scenario` reads the file. Use `${VAR:-default}` to provide a fallback value when the variable is unset. Unresolved variables without defaults are left as-is so the AI can flag them.

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
| `remember: "instruction"` | AI reads dynamic data from screen and holds it for later steps |
| `condition:` | Branch based on screen state — see below |

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
