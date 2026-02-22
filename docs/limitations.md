# Known Limitations

## Focus Stealing

Every input tool (`tap`, `type_text`, `press_key`, `swipe`, `drag`, `long_press`, `double_tap`) must make iPhone Mirroring the frontmost app before sending HID events. This means the tool will steal keyboard focus from whatever app you are currently using.

### Why

Karabiner's virtual HID keyboard and pointing device deliver events through the macOS HID system. macOS routes HID events to the frontmost application. There is no API to direct HID input to a background window.

### What This Means in Practice

If you are typing in a terminal or editor and an MCP tool fires, iPhone Mirroring will become frontmost and your terminal loses focus. After the tool completes, iPhone Mirroring retains focus — the server intentionally does not switch back to avoid per-call Space jitter.

Read-only tools (`screenshot`, `describe_screen`, `start_recording`, `stop_recording`, `status`, `get_orientation`, `check_health`, `list_skills`, `get_skill`) use the Accessibility API and do **not** steal focus.

### Mitigations

| Strategy | How It Helps |
|----------|-------------|
| **Separate macOS Space** | Put iPhone Mirroring in its own Space. The activation triggers a Space switch, so your cursor position and text selection in the other Space are preserved. |
| **Skill runner** | Chain multiple steps in a single skill (SKILL.md or YAML). Focus is acquired once at the start rather than stolen between each individual tool call. |
| **Batch your MCP work** | Run a sequence of phone interactions together, then return to your other work. Interleaving phone commands with terminal typing will cause repeated focus switches. |

### Alternatives That Don't Work

| Approach | Why It Fails |
|----------|-------------|
| `CGEvent` injection | iPhone Mirroring's compositor ignores programmatic `CGEvent` posts — it only responds to events from the system HID path. |
| Accessibility API actions | AX actions can trigger menu items (Home, App Switcher) but cannot simulate touch input on the mirrored display. |
| Clipboard paste (`Cmd+V`) | iPhone Mirroring does not bridge the Mac clipboard when paste is triggered programmatically. Tested with HID, AppleScript, and `CGEvent` — none work. |
| `NSRunningApplication.activate()` | Deprecated in macOS 14 with no replacement for cross-Space activation. Cannot reliably bring iPhone Mirroring to front. |

## Keyboard Layout Gaps

When the iPhone uses a non-US keyboard layout (e.g., Canadian-CSA), the server translates characters through `UCKeyTranslate` to find the correct HID keycodes. Two characters on the ISO section key (`§` and `±` on Canadian-CSA) cannot be typed because macOS and iPhone Mirroring disagree on the key mapping for that physical key. These characters are silently skipped.

## DriverKit Extension Persists After Uninstall

The DriverKit kernel extension remains loaded until the next reboot, even after uninstalling via `./uninstall-mirroir.sh` or `brew uninstall --zap`. This is standard macOS behavior for DriverKit extensions and does not affect functionality. The extension's `/Library/Application Support/org.pqrs` directory may be recreated while the kernel extension is still loaded — this is expected and clears after reboot.

## iOS Autocorrect

iOS applies autocorrect to HID-typed text the same way it does for physical keyboard input. Words may be silently changed after a space or punctuation is typed. Disable autocorrect in iPhone **Settings > General > Keyboard** if this causes issues.
