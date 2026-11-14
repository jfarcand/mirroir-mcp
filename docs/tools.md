# Tools Reference

All 42 tools exposed by the MCP server. Mutating tools require [permission](permissions.md) to appear in `tools/list`.

## Tool List

| Tool | Parameters | Description |
|------|-----------|-------------|
| `screenshot` | `settle_ms`?, `scale`?, `region`? | Capture the iPhone screen as a PNG, with a line stating its pixel size, the window points it shows, and the pixels-per-point factor |
| `describe_screen` | `scroll`?, `omit_screenshot`?, `query`?, `text_only`?, `settle_ms`? | Analyze the screen and return UI elements with tap coordinates plus a grid-overlaid screenshot. Uses local OCR or AI vision depending on `screenDescriberMode`. `scroll: true` does a full-page scroll to capture all elements. `omit_screenshot: true` returns text only (no image). `query` lists only elements whose text contains it (case- and accent-insensitive; icons omitted), and `text_only: true` drops the coordinates, so reading one value costs a line or two. `settle_ms` sets how long to wait for the screen to stop changing first. |
| `listen` | `seconds`?, `language`? | Hear what the phone plays, as text: records the sound iPhone Mirroring plays for up to `seconds` (1 to 60, default 10; it stops early when nothing plays from the start or once the sound has ended) and transcribes it on the Mac in `language` (BCP-47, default the Mac's). Read-only; needs macOS 26. See [Listening](#listening). |
| `start_recording` | `output_path`? | Start video recording of the mirrored screen |
| `stop_recording` | — | Stop recording and return the .mov file path. A recording that already ended on its own (display sleep can end it) still returns its file, with a note that the video stops early; `start_recording` refuses to start another until that file is collected |
| `tap` | `text`? or `x`, `y`; `image_size`?, `image_region`?, `cursor_mode`? | Tap visible text found by OCR (`text`; a miss lists the text on screen), or tap at coordinates relative to the mirroring window. With `image_size`, `x` and `y` are a position in a screenshot and are converted to window points |
| `double_tap` | `x`, `y`, `cursor_mode`? | Two rapid taps for zoom/text selection |
| `long_press` | `x`, `y`, `duration_ms`?, `cursor_mode`? | Hold tap for context menus (default 500ms) |
| `swipe` | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms`?, `cursor_mode`? | Swipe between two points (default 300ms) |
| `drag` | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms`?, `cursor_mode`? | Slow sustained drag for icons, sliders (default 1000ms) |
| `touch` | `action`, `x`?, `y`?, `duration_ms`? | Hold one finger across calls: `begin` at (x, y), `move` to (x, y) over `duration_ms` (1-5000ms, default 100ms), `end`, or `cancel` (always releases the button). Each move is placed against the window's live frame; if the window changed size (iPhone rotated, Mirroring resized or restarted) the touch is released and the move refused. Other pointing tools refuse while it is held; released automatically after 30s idle and when the server exits |
| `pinch` | `x`, `y`, `scale`, `duration_ms`? | Two-finger pinch centred at (x, y): `scale` > 1 spreads the fingers (zoom in), < 1 pinches them (zoom out); the spread ends at exactly `scale` times its start (0.1-10, 100-5000ms, default 500ms). Reaches iOS as a UIKit two-finger gesture (Maps, Photos); games that read raw touches may ignore it. Needs a Mac with a built-in trackpad or a Magic Trackpad; refused while a touch is held |
| `rotate` | `x`, `y`, `degrees`, `duration_ms`? | Two-finger rotation centred at (x, y) by `degrees`: positive counter-clockwise, negative clockwise (non-zero, up to 360 either way, 100-5000ms, default 500ms). Same delivery and trackpad requirement as `pinch` |
| `hold_keys` | `keys`, `duration_ms`?, `drag`? | Hold 1-6 keys for `duration_ms` (100-10000ms, default 1000ms), then release everything in reverse order. Keys are single unshifted characters (`w`), modifiers (`shift`, `command`, `option`, `control`), or named keys (`space`, `up`, ...). Plain keys re-post key-down every 50ms like a held physical key; modifiers are held without repeating. Optional `drag` `{from_x, from_y, to_x, to_y, button: left\|right}` holds that mouse button across the same duration. For games that switch to mouse/keyboard controls (e.g. Roblox: `w` walks while a right drag turns the camera); touch-only games ignore keys. Refused while a touch is held or when the mirroring window is not the frontmost app; stops early and releases everything if focus leaves it mid-hold |
| `type_text` | `text`, `clear` | Type text — adds to what the field holds; `clear: true` empties the focused field first (Cmd+A, then Delete; clear only a field you just focused, since with none focused Cmd+A acts on whatever the app selects) — activates iPhone Mirroring and sends keystrokes. Characters with no key are pasted one run at a time and each paste is confirmed by OCR; one not seen (or unreadable, like emoji) returns an error ([limitations](limitations.md#clipboard-paste-is-confirmed-by-ocr)) |
| `press_key` | `key`, `modifiers`? | Send a special key (return, escape, tab, delete, space, arrows) with optional modifiers (command, shift, option, control) |
| `shake` | — | Trigger shake gesture (Ctrl+Cmd+Z) for undo/dev menus |
| `launch_app` | `name` | Open app by name via Spotlight search; opens the top result only when it is an app (tapping its tile, or Return when no tile is read), so a missing app fails instead of opening a web or App Store result. When Spotlight never shows the typed name (on iOS 26 it can take typing only once per iPhone Mirroring session), it closes Spotlight and taps the Home Screen icon labeled exactly `name` on the page Home shows (no page is turned); apps on other pages, in folders, the Dock or only the App Library are not found that way |
| `open_url` | `url` | Open URL in Safari |
| `press_home` | — | Go to home screen. Like `press_app_switcher` and `spotlight`, it frees a paused session first and fails when the session is still paused, since iPhone Mirroring's menu answers without the iPhone receiving anything |
| `press_app_switcher` | — | Open app switcher |
| `press_back` | — | Navigate back by OCR-tapping the `<` back chevron, with a canonical-position fallback; on a macOS app target it presses Cmd+[. The reply names which was done and whether the screen changed; a press that left the screen unchanged is an error |
| `spotlight` | — | Open Spotlight search |
| `scroll_to` | `label`, `direction`?, `at`?, `max_scrolls`? | Scroll until a text element becomes visible via OCR; reports why it stopped when the text never shows |
| `reset_app` | `name` | Force-quit an app via the App Switcher |
| `measure` | `action`, `until`, `max_seconds`?, `name`? | Time a screen transition after an action |
| `run_steps` | `steps` | Run several proven steps in one call, in the [step grammar](#step-types) (`"tap: <text on screen>"`, `"tap: @324,113"` for a point, `"type: calculator"`, `"wait_for: Get"`, `"home"`). Every step is checked against the permission policy before the first runs; the run stops at the first failure and the reply ends with the text on screen |
| `set_network` | `mode` | Toggle network settings (airplane, Wi-Fi, cellular) via Settings |
| `get_orientation` | — | Report portrait/landscape and window dimensions |
| `status` | — | Connection state, window geometry, and device readiness |
| `check_health` | — | Comprehensive setup diagnostic: mirroring, accessibility, screen capture |
| `list_skills` | — | List available skills (SKILL.md and YAML) from project-local and global config dirs. A file is listed when it names `name` and `app` (a SKILL.md in its front matter; a YAML skill with steps too), so READMEs, `APP.md` files and patterns in the same tree are not; a YAML skill with the same name and app as a SKILL.md is listed once, as the SKILL.md |
| `get_skill` | `name` | Read a skill file (SKILL.md or YAML) with ${VAR} env substitution. Appends compilation status. |
| `generate_skill` | `action`, `app_name`?, `goal`?, `goals`?, `arrived_via`?, `action_type`?, `max_depth`?, `max_screens`?, `max_time`?, `strategy`?, `fresh`?, `seed`?, `skip_calibration`?, `explorer`?, `emit`?, `output_dir`? | Generate a SKILL.md by exploring an app. Session-based: start → capture → finish. `action: "explore"` runs autonomous exploration — `explorer: "bfs"` (default) or `"dfs"`. `fresh: false` resumes a persisted navigation graph; `seed` makes exploration ordering deterministic. `emit: true` (on `finish` / `explore`) also writes a runnable iOS leg into the consumer repo's `.mirroir/apps/<app>/` — see [Web and iOS in one scenario](web-and-ios.md); `output_dir` names the repo root when the server is not running from it. `save_compiled` and `mirroir record` write the same tree. |
| `list_targets` | — | List all configured automation targets with status, window size, and the tools each one lacks |
| `switch_target` | `target` | Switch active target for subsequent tool calls |
| `classify_screen` | `target`? | Group the current screen's OCR elements into UI components with an AI model: each component, its definition, and the elements it covers. Read-only |
| `calibrate_component` | `component_path`, `target`?, `scroll`? | Test a component definition (.md) against the current screen and return a diagnostic report |
| `record_step` | `step_index`, `type`, `label`?, `tap_x`?, `tap_y`?, `match_strategy`?, `elapsed_ms`?, `scroll_count`?, `scroll_direction`? | Record a compiled step during AI-driven skill execution; a tap with coordinates and no label also records the screen it led to, which replay must reach, and is refused when that screen is the one before the tap |
| `get_notes` | `topic`? | Read the notes an agent saved in earlier sessions about an app; without `topic`, list the topics that have notes |
| `save_note` | `topic`, `note`, `replaces`? | Save one short dated note for future sessions under a topic, usually the app's name |
| `save_compiled` | `skill_name`, `emit`?, `output_dir`? | Save accumulated compiled steps as .compiled.json next to the source skill (the speed cache `mirroir test` replays). `emit: true` also writes the walk into the consumer repo's `.mirroir/apps/<app>/` as a runnable iOS scenario — its app is the one the skill's opening `launch:` names; no `.compiled.json` is written into `.mirroir/`. See [Compiled Skills](compiled-skills.md#emitting-the-walk-into-mirroir). |

## Coordinates

Coordinates are in points relative to the mirroring window's top-left corner. Use `describe_screen` to get exact tap coordinates — it detects both text (via Vision OCR) and icons (via YOLO CoreML, if a model is installed). The grid overlay helps target any remaining unlabeled elements. A raw `screenshot` is in pixels, and the factor between pixels and points is not fixed: it follows the display, the `scale` argument and the `region` crop. Each screenshot's reply states its pixel size and that factor. To tap something only the image shows, pass its position in the image to `tap` as `x` and `y` with `image_size` (and `image_region` when the screenshot was cropped), and the point is converted for you.

## Describe Screen

`describe_screen` returns detected elements with their tap coordinates, plus a grid-overlaid screenshot for visual context. The backend depends on `screenDescriberMode`:

- **Local OCR (default)** — Apple Vision OCR for text recognition. If a YOLO CoreML model is installed in `~/.mirroir-mcp/models/`, the server auto-detects it and merges icon detections — giving the AI tap targets for non-text elements (buttons, toggles, icons) that text-only OCR misses. See [Icon Detection](screen-intelligence.md#icon-detection-yolo-coreml) for setup.
- **AI Vision** — When `screenDescriberMode` is `"vision"` (or `"auto"` with the embacle FFI linked), the screenshot is sent to an AI vision model that identifies UI elements semantically — cards, tabs, buttons, navigation structure — instead of raw text fragments. See [AI Vision Mode](screen-intelligence.md#ai-vision-mode-embacle) for setup.

Set `scroll: true` to perform a full-page scroll before returning results. The server scrolls through the entire page, deduplicates elements across viewports, and returns all detected elements — not just those visible in the initial viewport.

Set `omit_screenshot: true` to return only the text description without the base64 PNG image. This saves context window space during long automation sessions where screenshots aren't needed. The `MIRROIR_OMIT_SCREENSHOT` environment variable (or `describeScreenOmitScreenshot` setting) controls the default; the tool parameter overrides it per-call.

Set `settle_ms` to control how long the call waits for two identical consecutive frames before describing. In both OCR and vision mode the default is the `frameSettleTimeoutUs` setting (1.5s), exactly like `screenshot`: the mirrored frame lags the device, so a frame taken right after an action can still show the pre-action screen, and in vision mode a frame caught mid-transition would still bill a full model call. A constantly animated screen (a game scene, a video) never settles, so pass `settle_ms: 0` there to skip the wait. Requested values are capped at the `frameSettleMaxTimeoutUs` setting (10s), because the wait blocks the tool call.

A frame that is a uniform fill (rotation, launch, scene change) with no text or icons found by local OCR is reported as `SCREEN BLANK` (`screen_blank=true` in `_meta`). In vision mode such a frame is never sent to the model; a dark splash whose only content is a short label ("Tap to play") is still described, because the local OCR pass on the same frame finds the label.


On a **macOS app target**, the app reports its own text through Accessibility, exactly and with each element's frame. `describe_screen` lists that text marked `[tree]`, at the centre of its frame, and drops the pixel reading of the same text; everything the tree does not report (and everything on the iPhone, whose mirrored screen has no tree) stays read from pixels, unmarked:

```
Screen elements (tap coordinates in points; [tree] = exact text from the macOS accessibility tree, unmarked = read from pixels, may misread):
- "Notes.app" at (68, 116) [tree]
- "Recents" at (79, 69)
```

Only labels are taken from the tree: a region that merely has a name (a browser, a list), the group an app with no tree of its own exposes for its whole window (Chrome, Slack), and a text area holding a whole document are left to the pixel reading. `_meta` counts both sources (`tree_count`, `pixel_count`), and a line says so when the tree could not be read. Measured on macOS 26.5: Finder's tree reads in about 0.1 s, and its frames sit within 2 points of the OCR tap points.

## Typing Workflow

`type_text` and `press_key` send CGEvent key events addressed to the iPhone Mirroring process, after one window event makes the mirror the key window of its own app. iPhone Mirroring is not activated: the app you are using keeps focus (see [limitations](limitations.md#focus-stealing)).

- Characters are mapped to macOS virtual keycodes with automatic keyboard layout translation — non-US layouts (French AZERTY, German QWERTZ, etc.) are supported via UCKeyTranslate
- iOS autocorrect applies, and it rewrites words as they are typed (in Notes, "Thu teh adress" lands as "They the adress"; a French keyboard turns English words into French ones). After typing, `type_text` reads the text back from the screen; when the screen does not show what was typed, the call still succeeds and its result carries a notice saying so. A password field hides its text, so the notice is expected there.

## Key Press Workflow

`press_key` sends special keys that `type_text` can't handle — Return to submit forms, Tab to switch fields, Delete to erase, and arrow keys to move through lists or text.

**Important:** Modifier shortcuts reach iOS, but only the ones iOS itself implements do anything. In a focused text field Cmd+A, Cmd+C and Cmd+V work (a select-all, copy, delete, paste round trip restores the text), and Safari implements Cmd+L. Mac conventions such as Cmd+[ for back are not implemented by iOS apps and do nothing. `shake` (Ctrl+Cmd+Z) is translated by iPhone Mirroring into a device shake.

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

`scroll_to` scrolls until a target text element becomes visible via OCR. It checks if the element is already on screen before scrolling, and tells the end of the content from a scroll that has not arrived yet.

- `label` (required): Text to find on screen
- `direction` (default: "down"): where the content you want is. "down" shows what is below the screen (the finger moves up), "up" what is above, "left" and "right" what is to that side. To name the finger's motion instead, use `swipe`
- `max_scrolls` (default: 10): Maximum scroll attempts before giving up
- `at` (default: the window centre): the point `[x, y]` to scroll at, for a list inside the screen such as a carousel or a sheet

When the text never shows, the error says why the scrolling stopped. `stop_reason=end_of_content` means the content stopped advancing: it stood where it had stood on two (`scrollEndConfirmations`) of the last four reads (`scrollRevisitDepth`). One slow frame is not taken for the end, and neither is a list caught still pulled past its end on one read. Only the area that scrolls is compared, below the status bar and above the home indicator, so a clock ticking over does not count as movement. "Where it stood" means most of the text in the same place, not all of it (`scrollUnchangedTextShare`): two reads of a screen at rest never agree on every text. Pictures that move under text that stays put count as movement, and a screen with no text, such as a photo grid, is compared by its pixels. `stop_reason=max_scrolls` means the content was still advancing when the scroll budget ran out.

## Reset App

`reset_app` force-quits an app via the iOS App Switcher.

Steps:
1. Launch the app via Spotlight (handles localization — `Settings` → `Réglages` on a French iPhone).
2. Open the App Switcher. The just-launched app is the centered card.
3. Drag the centered card upward to dismiss it (touch drag, not scroll-wheel swipe — iOS only accepts touch events for card dismiss).
4. Return to the home screen.

Use before `launch_app` to ensure a fresh app state. In a skill run by `mirroir test`,
`reset_app:` is a destructive step that needs `--confirm-destructive`, except when the very next
step is a `launch:` of the same app (exact name, case-sensitive after trimming) — the pair every
emitted `.ios.yaml` flow opens with. Tunable via `appSwitcherCardXFraction`, `appSwitcherCardYFraction`, `appSwitcherSwipeDistance`, and `appSwitcherSwipeDurationMs` if your iPhone model places the centered card differently.

## Measure

`measure` times a screen transition: performs an action, then polls OCR until a target label appears. Reports the measured duration and optionally fails if it exceeds a threshold.

- `action` (required): Action string in `type:value` format — `tap:Label`, `launch:AppName`, or `press_key:return`
- `until` (required): Text label to wait for after the action
- `max_seconds` (optional): Maximum allowed seconds — fails if exceeded
- `name` (optional): Name for reporting (default: "measure")

## Set Network

`set_network` toggles network settings on the iPhone by navigating the Settings app. After toggling, it returns to the home screen. It finds the row by its label, read from the Settings Row sections of [`system-phrases.md`](../Sources/mirroir-mcp/Resources/system-phrases.md), which list the English labels (Airplane, Wi-Fi, Cellular); on a phone in another language, add the row's label there.

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

Patterns (`patterns/elements`, `patterns/screens`, `patterns/apps`, `drift-defaults.yaml`) are read from the mirroir-skills checkout: `$MIRROIR_SKILLS` when set (`mirroir-run` sets it on every `mirroir-mcp test` it starts), then the two directories above, then a `mirroir-skills` checkout beside the working directory. Emitting a `.mirroir/` scenario refuses to run when none of them holds `patterns/elements/text-cleanup.md`: its landmarks are cleaned with those rules.

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

## Notes

A skill says how to do a task. A note says what an agent learned on the way: where a control hides, the wording a screen uses, a step that fails and what works instead. `save_note` keeps one line under a topic, usually the app's name, and `get_notes` reads it back in a later session.

- Notes are plain Markdown files, one per topic, in `~/.mirroir-mcp/notes/`. You can read, edit and delete them.
- A note is one line of at most 500 characters, saved with its date. A topic holds at most 50; past that, `replaces` (the text of an earlier note) swaps one out, which is also how an agent corrects a note that stopped being true.
- `get_notes` is read-only and always available. `save_note` is hidden until you [allow it](permissions.md), like every tool that writes.
- A note is what an earlier session observed, not an instruction from you. `get_notes` says so each time, because an agent that reads a screen can be led to write down what that screen says. Notes never hold a password or a code by design, but nothing can check that: look at the files if you share the Mac.

## Listening

A screen shows what is written; `listen` gets what is said. Start a reel, a video or a voice message on the phone, then call `listen`: it records the sound iPhone Mirroring plays on the Mac and returns the words.

- Only the target app's sound is recorded, through ScreenCaptureKit, under the Screen & System Audio Recording grant mirroir already needs. Measured on macOS 26.5: the recording is whole even with the Mac's output muted.
- The words are transcribed on the Mac by macOS's own speech recognizer (SpeechAnalyzer). The audio never leaves the Mac and its temporary file is deleted once read; the reply holds the text only. The first time a language is used, macOS downloads its speech model once; a model already installed is used as it is.
- Pass `language` as the iPhone's language when it differs from the Mac's (`"fr-CA"`, `"en-US"`). Measured on the XR: 15 s of spoken Québec French transcribed in 0.5 s, nearly word for word.
- `seconds` is the longest it listens. It stops early in two cases: nothing plays during the first 4 s (`listenSilentStartSeconds`), and it then replies that nothing is playing (a muted or paused video) without transcribing; or sound played and then 3 s of silence followed it (`listenTrailingSilenceSeconds`), and it transcribes what it heard and says how long it recorded. Loudness alone decides, so a reel whose music never pauses is recorded for the whole `seconds`, even when it loops.
- Silence is reported as silence (a paused video, a muted phone), and speech in another language comes back as no words, with a hint to pass `language`.
- Two on-device engines can transcribe. `SpeechTranscriber` is used where macOS offers it; where it does not (measured: GitHub's macOS 26 virtual machines), macOS's dictation engine is used instead, and the reply names the engine. Dictation is less accurate: on the same sentence it heard "Ground the chicken… the green onion" where SpeechTranscriber heard "Brown the chicken… the green onions".
- Words only: it does not say who spoke, sung lyrics come out approximate, and it needs macOS 26 or later.

## Multi-Target

`list_targets` shows all configured automation targets (iPhone Mirroring, generic macOS windows such as an emulator or a desktop app) with their status, window size, and which is currently active. Each line also names the tools that do not exist on that target:

```
- iphone (active): connected (410x898) [iPhone Mirroring; every tool]
- telegram: connected (1200x800) [macOS App; unsupported here: launch_app, open_url, press_app_switcher, press_home, reset_app, set_network, shake, spotlight]
```

Those eight tools drive something only the iPhone has: Spotlight, the Home Screen, the App Switcher, the iOS shake shortcut. On a target without one, the tool (and the matching step in `run_steps` or a skill) is refused with a message that starts `<tool> is unsupported on target '<name>'`, says why, says that nothing was sent, and names the targets that do have it. It is never emulated: an iOS shortcut sent to a Mac app would do something else there.

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
| `clear_field` | calls `type_text` with `clear: true`, or Cmd+A then Delete in `mirroir test` and `run_steps` |
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
| `scene: { skill, max_frames, max_tokens, max_seconds, decider }` | plays a `kind: game` skill under a hard budget; `decider` names the move picker a `decider: required` skill needs — see [Scenes](skills-marketplace.md#scenes) |
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
