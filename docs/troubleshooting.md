# Troubleshooting

## Debug Mode

Pass `--debug` to enable verbose logging:

```bash
npx -y mirroir-mcp --debug
```

The flag works on every subcommand too (`mirroir-mcp --debug record …`,
`mirroir-mcp --debug test …`): their launch, tap and `reset_app` steps are then
logged the same way, appended to the log.

Logs are written to both stderr and `~/.mirroir-mcp/debug.log`. Logged events include permission checks, tap coordinates, focus state, and window geometry. Several servers can share the file (a client often starts two, and a debug server may run beside them), so it is append-only: every line names the process that wrote it (`[tag HH:mm:ss.SSS pid 1234]`), each start appends a `--- pid <n> started <time> ---` marker, and no process ever truncates it. A process that starts while the log is larger than `debugLogMaxBytes` (10 MB) moves it to `~/.mirroir-mcp/debug.log.1` first. To follow one server, filter on its pid: `grep "pid 1234]" ~/.mirroir-mcp/debug.log`.

`MIRROIR_DEBUG=1` (or `"debugLogging": true` in `settings.json`) turns on verbose logging where you cannot add `--debug`. In the Claude extension, turn on **Debug logging** in the extension's settings; it sets `MIRROIR_DEBUG`. Then quit and reopen Claude.

Even without `--debug`, the server always writes startup information to `~/.mirroir-mcp/debug.log` — permission mode, denied tools, and hidden tools. Check this file first when debugging permission issues.

Tail the log in a separate terminal:

```bash
tail -f ~/.mirroir-mcp/debug.log
```

Combine with permission bypass for full-access debugging:

```bash
npx -y mirroir-mcp --debug --yolo
```

`--yolo` is an alias for `--dangerously-skip-permissions`; either flag bypasses the permission policy.

## Modifier State Corruption (Alternating Caps)

If you see alternating uppercase/lowercase when typing through iPhone Mirroring (e.g., "LiKe ThIs"), this is a known Apple bug with modifier state tracking in the iPhone Mirroring compositor.

**Workarounds:** Toggle Caps Lock, disconnect and reconnect iPhone Mirroring, or reboot the Mac. See [Apple Community thread](https://discussions.apple.com/thread/254551671).

## Doctor

Run `mirroir doctor` to check all prerequisites at once. Each failed check includes a fix hint:

```bash
mirroir doctor
```

Use `--json` for machine-readable output. Colors appear only in a terminal: piped output is plain, and `--no-color` or a non-empty `NO_COLOR` turns them off there too.

Doctor also warns about each prompt file that overrides a built-in AI system prompt, with its path. Older `mirroir.sh` installs copied both `diagnosis.md` and `screen-describe.md` into `~/.mirroir-mcp/prompts/`; a copy you did not write is stale — delete it (see [System Prompts](configuration.md#system-prompts)).

## Development Watch Mode

During development, use `mirroir-watch.sh` to automatically rebuild and restart the server when source files change:

```bash
./mirroir-watch.sh --debug --dangerously-skip-permissions
```

The script uses `fswatch` to monitor `Sources/` for `.swift` file changes, rebuilds via `swift build`, and restarts the server process. Install fswatch with `brew install fswatch` if needed. The MCP client will need to reconnect after each restart.

## Common Issues

**Typed text never appears on the iPhone** — Keystrokes are addressed to the iPhone Mirroring process, so they cannot land in another app. When `type_text` reports success but nothing shows up, the phone side has stopped accepting typed keys (taps and Cmd shortcuts often still work). Quit iPhone Mirroring and open it again; the next input call reconnects. If the text appears but differs from what was sent, iOS autocorrect rewrote it: `type_text` says so in its result.

**iPhone Mirroring is not running** — If it was not running when the server started, the first input call starts it in the background (the app you are using stays in front) and waits up to 20 seconds for the session to connect, pressing Resume or Connect when the session shows them. If it was running and you quit it, nothing reopens it: `status` and every input say so, and you open it again yourself. Quitting it is a kill switch. A session that needs you (the iPhone in use, a Mac prompt) is reported instead of waited on.

**Taps don't register** — Run `mirroir doctor` to check prerequisites. Verify that iPhone Mirroring is connected (not showing "Connect to your iPhone" screen) and that Accessibility permissions are granted in System Settings > Privacy & Security > Accessibility.

**"A window of loginwindow covers ..." mid-run** — the Mac's screen saver or display sleep started. Taps and swipes mirroir sends do not count as activity for the idle timer, so mirroir keeps the display awake while a tool call, a `test`/`compile`/`record` run or a recording is active (`keepDisplayAwake`, on by default; `pmset -g assertions` lists it as `mirroir-mcp <tool>`). Between two tool calls nothing is held, so a run made of many short calls is covered only while each call lasts; whether the screen saver can start in the gap between two calls has not been measured. If it does, run `caffeinate -d` beside the session. A lock you trigger always wins.

**"Mirroring paused" screenshots** — Input tools, and the `test`, `compile` and `record` commands, press the window's own Resume, OK or Try Again control once; `screenshot` and `describe_screen` never press anything, so they show the interruption as it is. When the session stays blocked, the refusal quotes what the window says and names the next move: lock the iPhone ("iPhone in Use", timed out), turn on the Mac's Wi-Fi or Bluetooth, wait while it connects, or approve or cancel a Mac Touch ID or password prompt. A password is never typed for you. `status` and `mirroir doctor` report the same guidance.

**Taps refused with "off every display"** — The iPhone Mirroring window was moved past the edge of every screen, so a click there would reach nothing. Drag it back onto a display.

**iOS autocorrect mangling typed text** — iOS applies autocorrect to typed text. Disable autocorrect in iPhone Settings > General > Keyboard, or type words followed by spaces to confirm them before autocorrect triggers.

**YOLO model not loading** — Check `~/.mirroir-mcp/debug.log` for startup messages. The server logs whether it found a model (`OCR: auto-detected YOLO model, using Vision + YOLO`) or not (`OCR: no YOLO model found`). Verify the `.mlmodelc` directory exists in `~/.mirroir-mcp/models/` and is a valid compiled CoreML model. You can also set `yoloModelPath` in `settings.json` to point to a specific path.

**AI vision mode not activating** — Check `~/.mirroir-mcp/debug.log` for the agent-transport startup line. `Agent transport: embedded (Rust FFI) available; agent '<name>' -> embedded` means the embedded embacle runtime is linked and serves the configured agent (`-> http` means that agent goes over HTTP: a non-embacle provider, or a `runner:model` embacle model such as `embacle:claude`, which needs `embacle-server` running); `Agent transport: HTTP` means the embacle FFI is not linked into this binary. If it falls back to HTTP, verify that `embacle-ffi` is installed (`brew list embacle-ffi`) and rebuild from source (`swift build -c release`) — the FFI library (`libembacle.a`) must be linked at compile time. If linked but vision requests fail, check that your CLI agent (GitHub Copilot or Claude Code) is authenticated. Set `"screenDescriberMode": "ocr"` in `settings.json` to force local OCR as a fallback. (`agentTransport: "http"` in `settings.json` also forces HTTP even when the FFI is linked.)

**Compiled skill fails but you don't know why** — Use `--agent` to diagnose failures. Deterministic OCR analysis runs first (free, no API key), then optionally sends context to an AI for richer root-cause analysis:
```bash
mirroir test --agent skill.yaml                    # deterministic OCR diagnosis (YAML or SKILL.md)
mirroir test --agent claude-sonnet-5-5 skill.yaml  # deterministic + AI diagnosis
```
See the [AI-Assisted Diagnosis](skills-and-ci.md#ai-assisted-diagnosis) section for all supported providers and custom agent configuration.
