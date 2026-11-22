# FAQ

## Is this safe? Can the AI access my banking apps?

This tool gives an AI agent full control of your iPhone screen — it can tap anything, type anything, and open any app. That includes banking apps, messages, and payments.

To limit exposure:

- **Fail-closed permissions**: Without a config file, only the 14 read-only tools (such as `screenshot`, `describe_screen`, `status`) are exposed. Mutating tools are hidden entirely.
- **`blockedApps`**: Add sensitive apps to the deny list in `~/.mirroir-mcp/permissions.json`:
  ```json
  { "allow": ["tap", "swipe", "type_text"], "blockedApps": ["Wallet", "Banking"] }
  ```
- **Kill switch**: Quit iPhone Mirroring, unlock the iPhone, lock the Mac's screen, or quit the MCP client: each ends all input at once, and an app you quit is never reopened for the agent. Nothing runs in the background unless you install the opt-in [`serve` agent](cli.md#serve) yourself.

See [Security](security.md) for the full threat model and recommendations.

## Why does my cursor jump when the AI is working?

On iPhone Mirroring it only jumps for some gestures. Taps, typing and swipes (`tap`, `double_tap`, `long_press`, `type_text`, `press_key`, `launch_app`, `swipe`, `scroll_to`) are sent straight to the iPhone Mirroring window: your front app keeps focus and the cursor stays where it is. That holds through macOS 26; on a later macOS they are HID input too, unless `windowInput` is `on`. `drag`, `pinch` and `rotate` use HID input: they bring iPhone Mirroring forward for their duration, then return the front and the pointer. `hold_keys` and `touch` bring it to the front and leave it there.

**Mitigations for gestures:**

- **Separate macOS Space** — Put iPhone Mirroring in its own Space. Your cursor position and text selection in the other Space are preserved.
- **Batch interactions** — Run a sequence of phone commands together rather than interleaving with terminal work.
- **Skills** — Chain multiple steps in a skill (SKILL.md or YAML). Focus is taken once rather than per tool call.

Read-only tools (`screenshot`, `describe_screen`, `start_recording`, `stop_recording`, `status`, `get_orientation`, `check_health`, `list_skills`, `get_skill`, `list_targets`, `calibrate_component`) do **not** steal focus.

See [Known Limitations](limitations.md#focus-stealing) for details.

## Does it work with any iPhone app?

Yes. The MCP server operates at the screen level through macOS iPhone Mirroring — it taps, swipes, and types as if a human were interacting with the phone. No source code access, no app SDK, and no jailbreak required. If you can see it on screen, the AI can interact with it.

## Can it paste text from my Mac clipboard?

Only through Universal Clipboard. `Cmd+V` pastes the iPhone's clipboard, and the Mac's pasteboard reaches it through Handoff, asynchronously. `type_text` types every character it has a key for and pastes only the runs it has none for (emoji, CJK), confirming each paste by OCR. See [limitations](limitations.md#clipboard-paste-is-confirmed-by-ocr).

## How does input reach the iPhone?

Through macOS 26, taps, keys and swipes are events addressed to the iPhone Mirroring window; drags and two-finger gestures, and all input on a later macOS, are CGEvent posts on the system HID path. The iPhone Mirroring app (`com.apple.ScreenContinuity`) relays both to the connected iPhone. No kernel extensions, no root privileges, no helper daemons.

## Does it work with non-US keyboard layouts?

Yes, with opt-in configuration. Set `keyboardLayout` in `settings.json` (or the `IPHONE_KEYBOARD_LAYOUT` environment variable) to your iPhone's hardware keyboard layout, and the server reads that layout with `UCKeyTranslate` to press the key that types each character on it:

```bash
export IPHONE_KEYBOARD_LAYOUT="Canadian-CSA"
```

Accepted formats: `"Canadian-CSA"` or `"com.apple.keylayout.Canadian-CSA"`. Supported layouts include Canadian-CSA, French (AZERTY), German (QWERTZ), and others. Without this variable, the server sends US QWERTY keycodes (which is correct if your iPhone uses a US keyboard layout).

Two iPhones with different keyboards on one Mac: list both (`"keyboardLayout": ["Canadian-CSA", "US"]`). Characters the layouts type with different keys are pasted until `type_text` gets `keyboard_layout` for the connected phone, which is then remembered for it. See [limitations](limitations.md#iphones-with-different-keyboards-on-one-mac).

Dead-key compositions such as `ê` on Canadian-CSA are typed as the dead key then the base key. Characters the layout has no keys for, such as `<` on Canadian-CSA, are sent through the clipboard with a warning, which needs Universal Clipboard.

## What happens if iPhone Mirroring disconnects?

All input stops immediately. The MCP server detects the disconnection through the Accessibility API and reports it via the `status` tool. No commands can be sent to the phone while disconnected. Reconnecting iPhone Mirroring restores functionality without restarting the server.

## Can I restrict which tools the AI can use?

Yes. Drop a `permissions.json` file in `~/.mirroir-mcp/` (global) or `.mirroir-mcp/` (project-local):

```json
{
  "allow": ["tap", "swipe", "screenshot", "describe_screen"],
  "deny": ["launch_app"],
  "blockedApps": ["Wallet"]
}
```

Tools not in the allow list are hidden from the MCP client entirely — it never sees them. Project-local config takes priority over global.

See [Permissions](permissions.md) for all options.

## Does iOS autocorrect interfere with typed text?

Yes. iOS applies autocorrect to typed text the same way it does for physical keyboard input. Words may be silently changed after a space or punctuation is typed.

To disable: **iPhone Settings > General > Keyboard > Auto-Correction > Off**.

## Can multiple agents control the phone at once?

No. The MCP server communicates via stdin/stdout, so each MCP client session connects to one server instance. Multiple server instances posting CGEvent input simultaneously would cause unpredictable behavior — macOS routes events to the frontmost window, not to specific processes. Use one MCP session at a time.

## What is embacle and do I need it?

[embacle](https://github.com/dravr-ai/dravr-embacle) is an optional AI vision runtime that can be embedded into mirroir-mcp via Rust FFI. With it installed and `screenDescriberMode` set to `"vision"`, `describe_screen` uses an AI vision model instead of local OCR, producing richer semantic descriptions of UI elements (buttons, cards, tabs, navigation structure) rather than raw text fragments.

embacle routes requests through already-authenticated CLI tools (GitHub Copilot, Claude Code) — no separate API key needed. It is **not required** — local OCR works without it and is the default.

Install via:
```bash
brew tap dravr-ai/tap
brew trust --tap dravr-ai/tap   # recent Homebrew refuses untrusted taps
brew install embacle-ffi
swift build -c release  # rebuild: the manifest links the FFI once it is installed
```

The build detects `libembacle.a` at configure time, so installing it is what
enables the FFI and removing it returns you to OCR. To build the OCR-only
variant on a machine that has the library, set `MIRROIR_DISABLE_EMBACLE=1`.

See [AI Vision Mode](screen-intelligence.md#ai-vision-mode-embacle) for full setup.

## Should I use AI vision mode or local OCR?

| | Local OCR (default) | AI Vision (embacle) |
|---|---|---|
| Speed | ~200-500ms per screen | ~1-3s per screen |
| Cost | Free, offline | Uses API credits via CLI agent |
| Output | Raw text fragments with coordinates | Semantic UI elements (buttons, cards, tabs) |
| Best for | Speed-critical skill execution, regression testing, CI | Exploration of unfamiliar apps, complex layouts |

Use local OCR when speed matters and text is sufficient. Use AI vision when the agent needs to understand UI structure — especially during `generate_skill(action: "explore")` where semantic elements produce better exploration plans. You can combine both: use vision for exploration, then switch to OCR for compiled skill replay.

## How do I kill (force-quit) an app?

Use the `reset_app` tool with the app name. It launches the app via Spotlight, captures the foreground screen as an OCR fingerprint, opens the App Switcher, locates the matching card by intersecting that fingerprint with the App Switcher's OCR text, drags that card upward to dismiss it, and returns to the home screen. The flow fails **closed**: if launch fails, OCR is empty, or the card cannot be located, it returns an error instead of dragging at a hard-coded position.

If you want to do it manually with the lower-level tools, the gesture must be **`drag`**, not **`swipe`**:

- `swipe` posts a CGEvent **scroll wheel** event — iOS reads that as scrolling, not as a touch swipe.
- `drag` posts a CGEvent **mouse-down → move → up** sequence — iPhone Mirroring relays it as a touch gesture, which the App Switcher's card-dismiss interaction accepts. (Note: the one gesture iPhone Mirroring cannot relay is the iOS edge-swipe-back — neither `swipe` nor `drag` triggers `UIScreenEdgePanGestureRecognizer`, which is why back navigation relies on OCR-tapping the `<` chevron instead.)

Manual sequence: `press_app_switcher` → wait briefly → `drag(from_x: <half_width>, from_y: <half_height>, to_x: <half_width>, to_y: 80, duration_ms: 200)` → `press_home`.
