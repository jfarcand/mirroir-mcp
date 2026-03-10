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

If you see alternating uppercase/lowercase when typing through iPhone Mirroring (e.g., "LiKe ThIs"), this is a known Apple bug with modifier state tracking in the iPhone Mirroring compositor.

**Workarounds:** Toggle Caps Lock, disconnect and reconnect iPhone Mirroring, or reboot the Mac. See [Apple Community thread](https://discussions.apple.com/thread/254551671).

## Doctor

Run `mirroir doctor` to check all prerequisites at once. Each failed check includes a fix hint:

```bash
mirroir doctor
```

Use `--json` for machine-readable output or `--no-color` to disable ANSI colors.

## Development Watch Mode

During development, use `mirroir-watch.sh` to automatically rebuild and restart the server when source files change:

```bash
./mirroir-watch.sh --debug --dangerously-skip-permissions
```

The script uses `fswatch` to monitor `Sources/` for `.swift` file changes, rebuilds via `swift build`, and restarts the server process. Install fswatch with `brew install fswatch` if needed. The MCP client will need to reconnect after each restart.

## Common Issues

**Typing goes to the wrong app instead of iPhone** — The MCP server activates iPhone Mirroring via AppleScript before every input call. If keystrokes still land in the wrong app, check that your terminal has Accessibility permissions in System Settings. Note that focus stealing is expected — see [limitations](limitations.md#focus-stealing).

**Taps don't register** — Run `mirroir doctor` to check prerequisites. Verify that iPhone Mirroring is connected (not showing "Connect to your iPhone" screen) and that Accessibility permissions are granted in System Settings > Privacy & Security > Accessibility.

**"Mirroring paused" screenshots** — The MCP server auto-resumes paused sessions. If it persists, click the iPhone Mirroring window manually once.

**iOS autocorrect mangling typed text** — iOS applies autocorrect to typed text. Disable autocorrect in iPhone Settings > General > Keyboard, or type words followed by spaces to confirm them before autocorrect triggers.

**YOLO model not loading** — Check `~/.mirroir-mcp/mirroir.log` for startup messages. The server logs whether it found a model (`OCR: auto-detected YOLO model, using Vision + YOLO`) or not (`OCR: no YOLO model found`). Verify the `.mlmodelc` directory exists in `~/.mirroir-mcp/models/` and is a valid compiled CoreML model. You can also set `yoloModelPath` in `settings.json` to point to a specific path.

**Compiled skill fails but you don't know why** — Use `--agent` to diagnose failures. Deterministic OCR analysis runs first (free, no API key), then optionally sends context to an AI for richer root-cause analysis:
```bash
mirroir test --agent skill.yaml                    # deterministic OCR diagnosis (YAML or SKILL.md)
mirroir test --agent claude-sonnet-4-6 skill.yaml  # deterministic + AI diagnosis
```
See the [Agent Diagnosis](../README.md#agent-diagnosis) section for all supported providers and custom agent configuration.
