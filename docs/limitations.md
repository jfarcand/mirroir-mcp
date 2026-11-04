# Known Limitations

## Focus Stealing

On iPhone Mirroring, taps and keystrokes no longer take the front: the app you are using keeps keyboard focus and the cursor does not move. Swipes and other gestures still bring iPhone Mirroring to the front.

| Input | Front app | How it reaches the iPhone |
|-------|-----------|---------------------------|
| `tap`, `double_tap`, `long_press`, `press_back` (an OCR tap on the back chevron) | Kept | A window event addressed to the iPhone Mirroring window. It lands even when other windows cover the mirror. |
| `type_text`, `press_key`, `shake`, the typing inside `launch_app` and `open_url` | Kept | One event makes the mirror the key window of its own app, without activating it; the keys are then addressed to the iPhone Mirroring process. |
| `swipe`, `drag`, `scroll_to`, `hold_keys`, `touch`, `pinch`, `rotate` | Taken | HID events, which macOS routes to the frontmost app. iPhone Mirroring is activated first and keeps the front afterwards. |

Measured on macOS 26.5 with iTerm in front and the front app sampled every 0.2s: Clock tab taps, taps with a Finder window over the whole mirror, typing, a select-all/copy/delete/paste round trip, back-to-back Spotlight launches and a launch that first had to start iPhone Mirroring all left iTerm in front throughout.

### Why Gestures Still Take the Front

On macOS 26.5, a drag sent as window events loses its intermediate points (iOS sees a press and a release, so a drag reads as a tap), and scroll events routed to a window are ignored. Swipes, drags and multi-step gestures therefore stay on HID input, which needs iPhone Mirroring in front. Generic macOS window targets use HID input for everything.

Read-only tools (`screenshot`, `describe_screen`, `start_recording`, `stop_recording`, `status`, `get_orientation`, `check_health`, `list_skills`, `get_skill`, `list_targets`, `calibrate_component`) do **not** steal focus.

### Mitigations for Gestures

| Strategy | How It Helps |
|----------|-------------|
| **Separate macOS Space** | Put iPhone Mirroring in its own Space. The activation triggers a Space switch, so your cursor position and text selection in the other Space are preserved. |
| **Skill runner** | Chain multiple steps in a single skill (SKILL.md or YAML). Focus is taken once, at the first gesture, rather than between individual tool calls. |
| **Batch your MCP work** | Run a sequence of phone interactions together, then return to your other work. |
| **`cursor_mode: preserving`** | Coordinate tools (`tap`, `swipe`, `drag`, `long_press`, `double_tap`) accept an optional `cursor_mode` argument. `preserving` restores the cursor to its original position after a HID gesture. The default is `direct` for iPhone Mirroring and `preserving` for generic windows. This preserves cursor position, not application focus. |

## Cross-Space Interaction

The MCP client (e.g. the terminal running the server) and the target window **must be in the same macOS Space** for reliable interaction. `tap`, `type_text`, and `screenshot` all fail when the target window lives in a different Space — AppleScript `activate` plus CGEvent cannot reach across Spaces. This is the flip side of the "Separate macOS Space" mitigation above: a separate Space preserves your cursor and selection, but the server can only drive a window that shares the active Space with the client.

### Alternatives That Don't Work

| Approach | Why It Fails |
|----------|-------------|
| Accessibility API actions | AX actions can trigger menu items (Home, App Switcher) but cannot simulate touch input on the mirrored display. The mirrored content is an opaque video surface: when mirroring is active, the window's hosting view exposes **zero** child AX elements, so the AX tree cannot read or drive iOS UI. This is why the server relies on screenshots + OCR for screen content. |
| `NSRunningApplication.activate()` | Deprecated in macOS 14 with no replacement for cross-Space activation. Cannot reliably bring iPhone Mirroring to front. |

## Keyboard Layout Gaps

CGEvent keycodes are layout-independent physical keys, and the iPhone turns them into characters with its own hardware-keyboard layout. When `keyboardLayout` (or `IPHONE_KEYBOARD_LAYOUT`) names a non-US layout such as Canadian-CSA, the server reads macOS's copy of that layout (`LayoutMapper.keyTable`) and types each character with the key and Shift state that produce it there. With it empty or `US`, keystrokes come from the US QWERTY table in `CGKeyMap`.

From a non-US layout, mirroir takes single keystrokes (unshifted or shifted) and dead-key pairs (`ê` is `^` then `e` on Canadian-CSA). Characters on the Option layer, and characters the layout does not have (`<`, `[`, `|` on Canadian-CSA), are pasted through the clipboard, so they depend on Universal Clipboard (see below).

The setting must match the layout chosen on the iPhone. A mismatch types the wrong character rather than skipping it — with no layout set on a Canadian-CSA iPhone, `/` arrives as `é` and every URL is garbled.

### Clipboard paste is confirmed by OCR

`type_text` types every character it has a key for and pastes only the runs it has none for (emoji, CJK, symbols the layout lacks), one `Cmd+V` per run. `Cmd+V` pastes the *iPhone's* clipboard; the Mac pasteboard reaches it only through Universal Clipboard (Handoff on both ends, Bluetooth and Wi-Fi, same iCloud account), asynchronously. With Handoff off nothing arrives; with a lagging sync the device pastes its previous clipboard value.

So each paste is read back from the screen with local OCR before the next clipboard write: the last `pasteVerifyWindowChars` readable characters of the line — the pasted run plus the text typed just before it — must appear one more time than before the paste, within `pasteVerifyTimeoutUs`. A paste not seen stops the call with an error that names what was confirmed and what was not; the MCP tool returns `isError`, and a skill step fails. What this means in practice:

- **Emoji and pictographic symbols are never confirmed.** OCR has no glyph to read for them, so a run made only of them is still pasted but the call returns an error saying it is unverified. Check the screen yourself before relying on it.
- **Non-Latin scripts need `ocrLanguages`.** With the default `["en-US"]`, Vision does not read CJK, so a CJK paste that landed is reported as not seen. Add the script (e.g. `["ja-JP","en-US"]`).
- **Secure fields hide what was pasted.** A password field shows dots, so a paste into one cannot be confirmed; keyed characters are unaffected.
- **The confirmed text must sit on one visible line.** A field that wraps the pasted tail across lines, or scrolls it out of view, fails the check.
- **A mixed run is judged as a whole.** A pasted run holding both readable characters and emoji is reported unverified: a stale clipboard holding only the readable part would otherwise pass.

### Spotlight can hold a previous query

After an app is launched from Spotlight, iOS can reopen Spotlight still showing that query. In that state the iPhone ignores typed keys and Return — the Mac's own keyboard included — while taps still land, and on an iPhone XR (iOS 26) the keyboard stayed dead until iPhone Mirroring was quit and relaunched. Two Spotlight launches in a row hit it every time, which is exactly a `reset_app` followed by `launch`.

`launch_app` (and a skill's `launch` step) therefore works like this:

- It waits for Spotlight to appear, and opens it once more if a Home transition closed it.
- When Spotlight already shows the app as a tile (its name with an app icon above it: the held query's top hit, or a Siri suggestion), it taps that label instead of typing, then confirms Spotlight closed.
- Otherwise it types the name and presses Return only when the name appeared one more time than before; if it did not, it looks for the app's tile once more before failing without pressing Return.

A held query for a *different* app still fails the launch. Recover by quitting and relaunching iPhone Mirroring.

## Web and iOS Scenarios

A `mirroir-run` scenario can hold a web block and an iOS block ([Web and iOS in one scenario](web-and-ios.md)), with these limits:

- An iOS block needs macOS, iPhone Mirroring connected, and `mirroir-mcp`; on Linux it is refused by name.
- The two blocks run one after the other, not in parallel, and a scenario opens at most one block per surface.
- `cross_surface` compares token overlap, not meaning: two screens that say the same thing in different words score low.

## Modifier-State Corruption (Apple Bug)

iPhone Mirroring can intermittently corrupt modifier state, producing alternating-case output (`LiKe ThIs`) regardless of the input source — Mac keyboard, CGEvent, or otherwise. The same bug is [documented for Universal Control](https://discussions.apple.com/thread/254551671). The server sends correct modifiers for every keystroke; this is an Apple-side defect, not a mirroir bug. Workarounds: toggle Caps Lock, disconnect/reconnect iPhone Mirroring, or reboot the Mac.

## No On-Screen Keyboard

iPhone Mirroring acts as an external hardware keyboard, so iOS hides the virtual on-screen keyboard. There is no iOS setting to override this — it is a hard platform limitation.

### Impact on Testing

- Screenshots and OCR will never show the iOS keyboard. Tests that need to verify keyboard appearance, custom input accessories, or keyboard-driven UI cannot be validated through iPhone Mirroring.
- Text input itself works fine — `type_text` and `press_key` deliver keystrokes via CGEvent regardless of whether the virtual keyboard is visible.

## iOS Autocorrect

iOS applies autocorrect to typed text the same way it does for physical keyboard input. Words may be silently changed after a space or punctuation is typed. Disable autocorrect in iPhone **Settings > General > Keyboard** if this causes issues.
