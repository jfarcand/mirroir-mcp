# Known Limitations

## Focus Stealing

Every input tool (`tap`, `type_text`, `press_key`, `swipe`, `drag`, `long_press`, `double_tap`, `shake`, and `press_back` — which OCR-taps the back chevron) must make iPhone Mirroring the frontmost app before sending input events. This means the tool will steal keyboard focus from whatever app you are currently using.

### Why

CGEvent input is routed by macOS to the frontmost application. There is no API to direct input events to a background window.

### What This Means in Practice

If you are typing in a terminal or editor and an MCP tool fires, iPhone Mirroring will become frontmost and your terminal loses focus. After the tool completes, iPhone Mirroring retains focus — the server intentionally does not switch back to avoid per-call Space jitter.

Read-only tools (`screenshot`, `describe_screen`, `start_recording`, `stop_recording`, `status`, `get_orientation`, `check_health`, `list_skills`, `get_skill`, `list_targets`, `calibrate_component`) use the Accessibility API and do **not** steal focus.

### Mitigations

| Strategy | How It Helps |
|----------|-------------|
| **Separate macOS Space** | Put iPhone Mirroring in its own Space. The activation triggers a Space switch, so your cursor position and text selection in the other Space are preserved. |
| **Skill runner** | Chain multiple steps in a single skill (SKILL.md or YAML). Focus is acquired once at the start rather than stolen between each individual tool call. |
| **Batch your MCP work** | Run a sequence of phone interactions together, then return to your other work. Interleaving phone commands with terminal typing will cause repeated focus switches. |
| **`cursor_mode: preserving`** | Coordinate tools (`tap`, `swipe`, `drag`, `long_press`, `double_tap`) accept an optional `cursor_mode` argument. `preserving` restores the cursor to its original position after the operation. The default is `direct` for iPhone Mirroring and `preserving` for generic windows. This preserves cursor position, not application focus. |

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

After an app is launched from Spotlight, iOS can reopen Spotlight showing that query in an inactive state that ignores keystrokes; Return then launches the previous result. `launch_app` (and a skill's `launch` step) therefore reads the screen after typing the name and presses Return only when the name appeared one more time than before. Otherwise it fails without pressing Return, including when the held query happens to be the same app. Clear the Spotlight field on the device (its ✕ button) to recover.

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
