# FAQ

## Is this safe? Can the AI access my banking apps?

This tool gives an AI agent full control of your iPhone screen — it can tap anything, type anything, and open any app. That includes banking apps, messages, and payments.

To limit exposure:

- **Fail-closed permissions**: Without a config file, only read-only tools (screenshot, describe_screen, status) are exposed. Mutating tools are hidden entirely.
- **`blockedApps`**: Add sensitive apps to the deny list in `~/.mirroir-mcp/permissions.json`:
  ```json
  { "allow": ["tap", "swipe", "type_text"], "blockedApps": ["Wallet", "Banking"] }
  ```
- **Kill switch**: Closing the iPhone Mirroring window or locking the phone kills all input immediately. No persistent background access is possible.

See [Security](security.md) for the full threat model and recommendations.

## Why does my cursor jump when the AI is working?

Every input tool (`tap`, `type_text`, `swipe`, etc.) must make iPhone Mirroring the frontmost app before sending HID events. macOS routes HID input to the frontmost application — there is no API to direct input to a background window.

**Mitigations:**

- **Separate macOS Space** — Put iPhone Mirroring in its own Space. Your cursor position and text selection in the other Space are preserved.
- **Batch interactions** — Run a sequence of phone commands together rather than interleaving with terminal work.
- **Skills** — Chain multiple steps in a skill (SKILL.md or YAML). Focus is acquired once rather than per-tool-call.

Read-only tools (`screenshot`, `describe_screen`, `start_recording`, `stop_recording`, `status`, `get_orientation`, `check_health`, `list_skills`, `get_skill`) do **not** steal focus.

See [Known Limitations](limitations.md#focus-stealing) for details.

## Does it work with any iPhone app?

Yes. The MCP server operates at the screen level through macOS iPhone Mirroring — it taps, swipes, and types as if a human were interacting with the phone. No source code access, no app SDK, and no jailbreak required. If you can see it on screen, the AI can interact with it.

## Can it paste text from my Mac clipboard?

No. iPhone Mirroring does not bridge the Mac clipboard when paste is triggered programmatically. This was tested extensively with HID keystrokes (`Cmd+V`), AppleScript, `CGEvent`, and Accessibility API actions — none work. The clipboard bridge relies on the Continuity/Handoff stack which only responds to physical user input.

Text is typed character-by-character through Karabiner's virtual HID keyboard instead.

## Why does it need a DriverKit virtual HID?

iPhone Mirroring's compositor ignores programmatic `CGEvent` injection — it only responds to events from the system HID path. A DriverKit virtual HID keyboard and pointing device that appears as real hardware to macOS is the only way to deliver touch and keyboard input to the mirrored iPhone.

The installer uses the [standalone Karabiner DriverKit package](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice) by default — just the virtual HID device, no keyboard grabber, no modifier corruption. If you already have Karabiner-Elements installed, the installer detects it and reuses the existing DriverKit extension instead.

See [Architecture](architecture.md) for the full input path diagram.

## Does it work with non-US keyboard layouts?

Yes, with opt-in configuration. Set the `IPHONE_KEYBOARD_LAYOUT` environment variable to your iPhone's hardware keyboard layout, and the server uses `UCKeyTranslate` to map characters to the correct HID keycodes:

```bash
export IPHONE_KEYBOARD_LAYOUT="Canadian-CSA"
```

Accepted formats: `"Canadian-CSA"` or `"com.apple.keylayout.Canadian-CSA"`. Supported layouts include Canadian-CSA, French (AZERTY), German (QWERTZ), and others. Without this variable, the server sends US QWERTY keycodes (which is correct if your iPhone uses a US keyboard layout).

**Known gap:** Two characters on the ISO section key (`§` and `±` on Canadian-CSA) cannot be typed because macOS and iPhone Mirroring disagree on the key mapping for that physical key. These characters are silently skipped.

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

Yes. iOS applies autocorrect to HID-typed text the same way it does for physical keyboard input. Words may be silently changed after a space or punctuation is typed.

To disable: **iPhone Settings > General > Keyboard > Auto-Correction > Off**.

## Can multiple users or agents control the phone at once?

No. The helper daemon accepts one client connection at a time on a single Unix socket. If a second MCP server connects, the first is disconnected. There is no multiplexing or concurrent access.
