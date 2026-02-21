# Troubleshooting

## Debug Mode

Pass `--debug` to enable verbose logging:

```bash
npx -y mirroir-mcp --debug
```

Logs are written to both stderr and `~/.mirroir-mcp/debug.log` (truncated on each startup). Logged events include permission checks, tap coordinates, focus state, and window geometry.

Even without `--debug`, the server always writes startup information to `~/.mirroir-mcp/debug.log` — permission mode, denied tools, and hidden tools. Check this file first when debugging permission issues.

Tail the log in a separate terminal:

```bash
tail -f ~/.mirroir-mcp/debug.log
```

Combine with permission bypass for full-access debugging:

```bash
npx -y mirroir-mcp --debug --yolo
```

## Modifier State Corruption (Alternating Caps)

If you see alternating uppercase/lowercase when typing through iPhone Mirroring (e.g., "LiKe ThIs"), this is a known Apple bug with modifier state tracking. Karabiner-Elements exacerbates it because its keyboard grabber (`karabiner_grabber`) intercepts and re-routes all keyboard input through the virtual HID device, causing the OS to lose track of modifier state.

**Fix:** The recommended setup uses the [standalone Karabiner DriverKit package](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice) instead of full Karabiner-Elements. The standalone package provides only the virtual HID device — no keyboard grabber, no modifier corruption.

If you ran `mirroir.sh` or `npx mirroir-mcp install`, the standalone package was installed automatically (unless you already had Karabiner-Elements).

**If you want to keep Karabiner-Elements:** The alternating caps bug is intermittent. Workarounds include toggling Caps Lock, disconnecting and reconnecting iPhone Mirroring, or rebooting the Mac. See [Karabiner #3035](https://github.com/pqrs-org/Karabiner-Elements/issues/3035) and [Apple Community thread](https://discussions.apple.com/thread/254551671).

## Doctor

Run `mirroir doctor` to check all 10 prerequisites at once. Each failed check includes a fix hint:

```bash
mirroir doctor
```

Use `--json` for machine-readable output or `--no-color` to disable ANSI colors.

## Common Issues

**`keyboard_ready: false`** — The DriverKit extension isn't running. Go to **System Settings > General > Login Items & Extensions** and enable the Karabiner DriverKit toggle. If you have Karabiner-Elements, enable all its toggles. You may need to enter your password.

**Typing goes to the wrong app instead of iPhone** — The MCP server activates iPhone Mirroring via AppleScript before every input call. If keystrokes still land in the wrong app, check that your terminal has Accessibility permissions in System Settings. Note that focus stealing is expected — see [limitations](limitations.md#focus-stealing).

**Taps don't register** — Check that the helper is running:
```bash
echo '{"action":"status"}' | nc -U /var/run/mirroir-helper.sock
```
If not responding, restart: `sudo brew services restart mirroir-mcp` or `sudo ./scripts/reinstall-helper.sh`.

**"Mirroring paused" screenshots** — The MCP server auto-resumes paused sessions. If it persists, click the iPhone Mirroring window manually once.

**iOS autocorrect mangling typed text** — iOS applies autocorrect to typed text. Disable autocorrect in iPhone Settings > General > Keyboard, or type words followed by spaces to confirm them before autocorrect triggers.

**Compiled scenario fails but you don't know why** — Use `--agent` to diagnose failures. Deterministic OCR analysis runs first (free, no API key), then optionally sends context to an AI for richer root-cause analysis:
```bash
mirroir test --agent scenario.yaml                    # deterministic OCR diagnosis (YAML or SKILL.md)
mirroir test --agent claude-sonnet-4-6 scenario.yaml  # deterministic + AI diagnosis
```
See the [Agent Diagnosis](../README.md#agent-diagnosis) section for all supported providers and custom agent configuration.
