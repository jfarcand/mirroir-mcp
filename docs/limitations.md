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
| Clipboard paste (`Cmd+V`) | iPhone Mirroring does not bridge the Mac clipboard when paste is triggered programmatically. Tested with HID, AppleScript, and `CGEvent` — none work. |
| `NSRunningApplication.activate()` | Deprecated in macOS 14 with no replacement for cross-Space activation. Cannot reliably bring iPhone Mirroring to front. |

## Keyboard Layout Gaps

CGEvent keycodes are layout-independent physical keys. When the iPhone uses a non-US keyboard layout (e.g., Canadian-CSA), the server builds a character substitution table (`LayoutMapper`) that maps each character to its US-QWERTY physical-key equivalent before looking up the keycode in `CGKeyMap`. Layout substitution is **off by default**; it activates only when a non-US layout is detected on the Mac, or when you opt in via the `IPHONE_KEYBOARD_LAYOUT` environment variable.

Characters with no `CGKeyMap` mapping after substitution cannot be typed (e.g. `§` and `±` on the ISO section key of Canadian-CSA, where macOS and iPhone Mirroring disagree on the physical key). These characters are skipped and reported back: `type_text` returns `success: true` with a warning of the form `Skipped N character(s) with no key mapping` — they are not silently dropped.

A layout table that does not match the phone's active keyboard types the wrong character rather than skipping it. On an iPhone whose keyboard differs from the configured `Canadian-CSA` table, `/` has been observed arriving as `é`, which garbles every URL — `type_text` of a URL and a scenario `open_url:` step both fail. Open the page another way (a bookmark, a link, or an address without slashes) until the table matches.

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
