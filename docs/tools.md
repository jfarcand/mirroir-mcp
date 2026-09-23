# Tools Reference

All 38 tools exposed by the MCP server. Mutating tools require [permission](permissions.md) to appear in `tools/list`.

## Tool List

| Tool | Parameters | Description |
|------|-----------|-------------|
| `screenshot` | — | Capture the iPhone screen as base64 PNG |
| `describe_screen` | `scroll`?, `omit_screenshot`? | Analyze the screen and return UI elements with tap coordinates plus a grid-overlaid screenshot. Uses local OCR or AI vision depending on `screenDescriberMode`. `scroll: true` does a full-page scroll to capture all elements. `omit_screenshot: true` returns text only (no image). |
| `start_recording` | `output_path`? | Start video recording of the mirrored screen |
| `stop_recording` | — | Stop recording and return the .mov file path |
| `tap` | `x`, `y`, `cursor_mode`? | Tap at coordinates (relative to mirroring window) |
| `double_tap` | `x`, `y`, `cursor_mode`? | Two rapid taps for zoom/text selection |
| `long_press` | `x`, `y`, `duration_ms`?, `cursor_mode`? | Hold tap for context menus (default 500ms) |
| `swipe` | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms`?, `cursor_mode`? | Swipe between two points (default 300ms) |
| `drag` | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms`?, `cursor_mode`? | Slow sustained drag for icons, sliders (default 1000ms) |
| `touch` | `action`, `x`?, `y`?, `duration_ms`? | Hold one finger across calls: `begin` at (x, y), `move` to (x, y) over `duration_ms` (1-5000ms, default 100ms), `end`, or `cancel` (always releases the button). Each move is placed against the window's live frame; if the window changed size (iPhone rotated, Mirroring resized or restarted) the touch is released and the move refused. Other pointing tools refuse while it is held; released automatically after 30s idle and when the server exits |
| `pinch` | `x`, `y`, `scale`, `duration_ms`? | Two-finger pinch centred at (x, y): `scale` > 1 spreads the fingers (zoom in), < 1 pinches them (zoom out); the spread ends at exactly `scale` times its start (0.1-10, 100-5000ms, default 500ms). Reaches iOS as a UIKit two-finger gesture (Maps, Photos); games that read raw touches may ignore it. Needs a Mac with a built-in trackpad or a Magic Trackpad; refused while a touch is held |
| `rotate` | `x`, `y`, `degrees`, `duration_ms`? | Two-finger rotation centred at (x, y) by `degrees`: positive counter-clockwise, negative clockwise (non-zero, up to 360 either way, 100-5000ms, default 500ms). Same delivery and trackpad requirement as `pinch` |
| `hold_keys` | `keys`, `duration_ms`?, `drag`? | Hold 1-6 keys for `duration_ms` (100-10000ms, default 1000ms), then release everything in reverse order. Keys are single unshifted characters (`w`), modifiers (`shift`, `command`, `option`, `control`), or named keys (`space`, `up`, ...). Plain keys re-post key-down every 50ms like a held physical key; modifiers are held without repeating. Optional `drag` `{from_x, from_y, to_x, to_y, button: left\|right}` holds that mouse button across the same duration. For games that switch to mouse/keyboard controls (e.g. Roblox: `w` walks while a right drag turns the camera); touch-only games ignore keys. Refused while a touch is held or when the mirroring window is not the frontmost app; stops early and releases everything if focus leaves it mid-hold |
| `type_text` | `text` | Type text — activates iPhone Mirroring and sends keystrokes |
| `press_key` | `key`, `modifiers`? | Send a special key (return, escape, tab, delete, space, arrows) with optional modifiers (command, shift, option, control) |
| `shake` | — | Trigger shake gesture (Ctrl+Cmd+Z) for undo/dev menus |
| `launch_app` | `name` | Open app by name via Spotlight search |
| `open_url` | `url` | Open URL in Safari |
| `press_home` | — | Go to home screen |
| `press_app_switcher` | — | Open app switcher |
| `press_back` | — | Navigate back by OCR-tapping the `<` back chevron, with a canonical-position fallback |
| `spotlight` | — | Open Spotlight search |
| `scroll_to` | `label`, `direction`?, `max_scrolls`? | Scroll until a text element becomes visible via OCR |
| `reset_app` | `name` | Force-quit an app via the App Switcher |
| `measure` | `action`, `until`, `max_seconds`?, `name`? | Time a screen transition after an action |
| `set_network` | `mode` | Toggle network settings (airplane, Wi-Fi, cellular) via Settings |
| `get_orientation` | — | Report portrait/landscape and window dimensions |
| `status` | — | Connection state, window geometry, and device readiness |
| `check_health` | — | Comprehensive setup diagnostic: mirroring, accessibility, screen capture |
| `list_skills` | — | List available skills (SKILL.md and YAML) from project-local and global config dirs |
| `get_skill` | `name` | Read a skill file (SKILL.md or YAML) with ${VAR} env substitution. Appends compilation status. |
| `generate_skill` | `action`, `app_name`?, `goal`?, `goals`?, `arrived_via`?, `action_type`?, `max_depth`?, `max_screens`?, `max_time`?, `strategy`?, `fresh`?, `seed`?, `skip_calibration`?, `explorer`?, `emit`?, `output_dir`? | Generate a SKILL.md by exploring an app. Session-based: start → capture → finish. `action: "explore"` runs autonomous exploration — `explorer: "bfs"` (default) or `"dfs"`. `fresh: false` resumes a persisted navigation graph; `seed` makes exploration ordering deterministic. `emit: true` (on `finish` / `explore`) also writes a runnable iOS leg into the consumer repo's `.mirroir/apps/<app>/` — see [Web and iOS in one scenario](web-and-ios.md); `output_dir` names the repo root when the server is not running from it. |
| `list_targets` | — | List all configured automation targets with status and window size |
| `switch_target` | `target` | Switch active target for subsequent tool calls |
| `calibrate_component` | `component_path`, `target`?, `scroll`? | Test a component definition (.md) against the current screen and return a diagnostic report |
| `record_step` | `step_index`, `type`, `label`?, `tap_x`?, `tap_y`?, `confidence`?, `match_strategy`?, `elapsed_ms`?, `scroll_count`?, `scroll_direction`? | Record a compiled step during AI-driven skill execution |
| `save_compiled` | `skill_name` | Save accumulated compiled steps as .compiled.json next to the source skill |

## Coordinates

Coordinates are in points relative to the mirroring window's top-left corner. Use `describe_screen` to get exact tap coordinates — it detects both text (via Vision OCR) and icons (via YOLO CoreML, if a model is installed). The grid overlay helps target any remaining unlabeled elements. For raw screenshots, coordinates are Retina 2x — divide pixel coordinates by 2 to get tap coordinates.

## Describe Screen

`describe_screen` returns detected elements with their tap coordinates, plus a grid-overlaid screenshot for visual context. The backend depends on `screenDescriberMode`:

- **Local OCR (default)** — Apple Vision OCR for text recognition. If a YOLO CoreML model is installed in `~/.mirroir-mcp/models/`, the server auto-detects it and merges icon detections — giving the AI tap targets for non-text elements (buttons, toggles, icons) that text-only OCR misses. See [Icon Detection](../README.md#icon-detection-yolo-coreml) for setup.
- **AI Vision** — When `screenDescriberMode` is `"vision"` (or `"auto"` with the embacle FFI linked), the screenshot is sent to an AI vision model that identifies UI elements semantically — cards, tabs, buttons, navigation structure — instead of raw text fragments. See [AI Vision Mode](../README.md#ai-vision-mode-embacle) for setup.

Set `scroll: true` to perform a full-page scroll before returning results. The server scrolls through the entire page, deduplicates elements across viewports, and returns all detected elements — not just those visible in the initial viewport.

Set `omit_screenshot: true` to return only the text description without the base64 PNG image. This saves context window space during long automation sessions where screenshots aren't needed. The `MIRROIR_OMIT_SCREENSHOT` environment variable (or `describeScreenOmitScreenshot` setting) controls the default; the tool parameter overrides it per-call.

## Typing Workflow

`type_text` and `press_key` route keyboard input through the CGEvent keyboard interface. If iPhone Mirroring isn't already frontmost, the MCP server activates it once (which may trigger a macOS Space switch) and stays there. Subsequent keyboard tool calls reuse the active window without switching again.

- Characters are mapped to macOS virtual keycodes with automatic keyboard layout translation — non-US layouts (French AZERTY, German QWERTZ, etc.) are supported via UCKeyTranslate
- iOS autocorrect applies — type carefully or disable it on the iPhone

## Key Press Workflow

`press_key` sends special keys that `type_text` can't handle — Return to submit forms, Tab to switch fields, Delete to erase, and arrow keys to move through lists or text.

**Important:** Keyboard shortcuts with modifiers (Cmd+N, Cmd+Z, etc.) do **not** work with iOS apps through iPhone Mirroring. iOS apps do not receive modifier-key combinations through the mirroring compositor. The only modifier combination that works is `shake` (Ctrl+Cmd+Z), which is a Mac-level action that iPhone Mirroring translates to a device shake.

For navigating within apps, combine `spotlight` + `type_text` + `press_key`. For example: `spotlight` → `type_text "Messages"` → `press_key return` to launch Messages.

## Games and Multi-Touch

iPhone Mirroring gives an app **one pointer touch**: every mouse and trackpad on the Mac merges into it, and a second button or a second mouse only moves that same touch. Three tools cover what games need within that limit, each measured on a real iPhone:

| Game control | Tool | Example |
|---|---|---|
| Virtual joystick, press-and-hold, sustained drag | `touch` | `touch(action:"begin", x:132, y:340)`, then `touch(action:"move", x:132, y:290)` keeps the character walking; `touch(action:"end")` lifts the finger |
| Keyboard and mouse controls (games that switch to them, e.g. Roblox) | `hold_keys` | `hold_keys(keys:["w"], duration_ms:3000, drag:{from_x:430, from_y:150, to_x:650, to_y:150, button:"right"})` walks forward while the camera turns |
| Zoom and rotate gestures in maps, photos, and other gesture-recognizer UIs | `pinch`, `rotate` | `pinch(x:200, y:400, scale:2.5)` |

What does not work, and why:

- **Two independent fingers in a touch-only game.** `pinch` and `rotate` do produce two touches, but they reach iOS as a trackpad gesture. UIKit gesture recognizers accept them; game engines that read raw finger touches (Brawl Stars, measured) ignore them.
- **A second touch while one is held.** A click during a pinch is dropped, a pinch during a held click is ignored, and the right button or a second mouse only moves the held touch.
- **A two-finger trackpad slide** arrives on the phone as scroll, which iOS turns into a single pan touch.

True independent multi-touch would need a virtual touchscreen HID device on the Mac, which requires Apple's `com.apple.developer.hid.virtual.device` entitlement; whether iPhone Mirroring forwards such a device is unmeasured.

## Scroll To

`scroll_to` scrolls in a direction until a target text element becomes visible via OCR. It checks if the element is already on screen before scrolling, and detects scroll exhaustion (when the screen content stops changing, meaning the list has reached its end).

- `label` (required): Text to find on screen
- `direction` (default: "up"): Scroll direction — "up" means swipe up (scroll content down), matching iOS convention
- `max_scrolls` (default: 10): Maximum scroll attempts before giving up

## Reset App

`reset_app` force-quits an app via the iOS App Switcher.

Steps:
1. Launch the app via Spotlight (handles localization — `Settings` → `Réglages` on a French iPhone).
2. Open the App Switcher. The just-launched app is the centered card.
3. Drag the centered card upward to dismiss it (touch drag, not scroll-wheel swipe — iOS only accepts touch events for card dismiss).
4. Return to the home screen.

Use before `launch_app` to ensure a fresh app state. Tunable via `appSwitcherCardXFraction`, `appSwitcherCardYFraction`, `appSwitcherSwipeDistance`, and `appSwitcherSwipeDurationMs` if your iPhone model places the centered card differently.

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

## Skills

Skills are files that describe multi-step test flows as intents, not scripts. They can be written in **SKILL.md** format (YAML front matter + markdown body — the recommended format) or **YAML** format (legacy). The server provides two readonly tools for skill discovery and reading — the AI is the execution engine that interprets steps and calls existing MCP tools.

### Why AI Execution?

Steps like `tap: "Email"` don't specify coordinates — the AI calls `describe_screen`, finds the element by fuzzy matching, and taps it. This matters because real iOS apps change between versions, vary across screen sizes, and throw unexpected UI (permission prompts, keyboard suggestions, notification banners). A deterministic script runner would need exact strings and hardcoded timeouts. The AI adapts: it scrolls to find off-screen elements, dismisses unexpected dialogs, retries failed steps, and flags unresolved `${VAR}` placeholders. Skills declare *what* should happen; the AI figures out *how*.

### Directory Layout

```
~/.mirroir-mcp/skills/          # global skills
<cwd>/.mirroir-mcp/skills/      # project-local skills (overrides global)
```

Both directories are scanned recursively, so you can organize skills into subdirectories (e.g. `apps/slack/send-message.md`). Project-local skills with the same relative path override global ones. When both a `.md` and `.yaml` file exist with the same stem name, the `.md` file takes precedence.

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

Convert existing YAML skills with `mirroir migrate`:

```bash
mirroir migrate skill.yaml                            # convert a single file
mirroir migrate --dir path/to/skills/                 # convert all YAML files in a directory
mirroir migrate --output-dir ./converted/ skill.yaml  # write .md files to alternate directory
mirroir migrate --dry-run skill.yaml                  # preview without writing
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

## Multi-Target

`list_targets` shows all configured automation targets (iPhone Mirroring, Android emulators, generic macOS windows) with their status, window size, and which is currently active.

`switch_target` changes the active target for all subsequent tool calls. Use it in skills with the `target:` step to automate workflows that span multiple devices or windows: `target: { kind: ios }` selects the iPhone Mirroring target, and `target: { kind: macos, name: "<targets.json name>" }` selects a configured desktop window. The map is the same shape `mirroir-run` parses, so one scenario file reads the same on both sides.

## Calibrate Component

`calibrate_component` tests a [component definition](components.md) against the current live screen. It OCRs the screen, runs the full detection pipeline against your definition, and returns a diagnostic report showing which rows matched, which didn't, and why.

Pass the path to a `.md` component definition file. The report includes per-row analysis with zone, element count, confidence scores, and match/mismatch reasons. Use it to validate and tune match rules before deploying a component for exploration.

See [Patterns & Skills](components.md) for element pattern format, screen recipes, APP.md descriptions, and the calibration workflow.

## Screen Recipes & APP.md

During BFS exploration, the system automatically:

1. **Loads screen recipes** — matches detected components against archetype recipes (settings-list, dashboard, social-feed, etc.) to understand navigation patterns
2. **Loads APP.md** — finds a matching app description by name and applies skip lists, obstacle auto-dismiss rules, and exploration context
3. **Refines strategy** — recipe match may switch from `mobile` to `social` strategy when infinite-scroll content is detected

Both are opt-in: without recipe files or APP.md, the explorer behaves exactly as before.

See [Patterns & Skills](components.md) for element patterns, screen recipes, APP.md format, and file locations.

### Variable Substitution

`${VAR}` placeholders are resolved from environment variables when `get_skill` reads the file (both SKILL.md and YAML formats). Use `${VAR:-default}` to provide a fallback value when the variable is unset. Unresolved variables without defaults are left as-is so the AI can flag them.

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
| `long_press: "Label"` | calls `describe_screen` to find element, then `long_press` |
| `drag: { from, to }` | calls `describe_screen` to find elements, then `drag` between them |
| `wait_for: "Label"` | polls `describe_screen` until element appears |
| `assert_visible` / `assert_not_visible` | checks via `describe_screen` |
| `screenshot: "label"` | captures and labels in report |
| `press_key` | calls `press_key` with optional modifiers |
| `press_home` | calls `press_home` to return to home screen |
| `open_url` | calls `open_url` |
| `shake` | calls `shake` |
| `scroll_to: "Label"` | calls `scroll_to` — scrolls until element visible |
| `reset_app: "AppName"` | calls `reset_app` — force-quit via App Switcher |
| `set_network: "mode"` | calls `set_network` — toggle airplane/wifi/cellular |
| `measure: { action, until, max }` | calls `measure` — time screen transitions |
| `target: { kind: ios }` / `target: { kind: macos, name: "…" }` | calls `switch_target` — switch to the iPhone or to a configured desktop window |
| `remember: "instruction"` | AI reads dynamic data from screen and holds it for later steps |
| `condition:` | Branch based on screen state — see below |
| `repeat:` | Loop over steps until a screen condition is met — see below |
| `verify: "instruction"` | AI-only step — the AI interprets the instruction against the current screen |
| `summarize: "instruction"` | AI-only step — the AI interprets the instruction against the current screen |

### Conditions

Skills can branch using `condition` steps. The AI calls `describe_screen` to evaluate the condition, then executes the matching branch:

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

Skills can loop using `repeat` steps. The AI checks a screen condition before each iteration and stops when the condition fails or `max` is reached:

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
