# CLI tools

The recorder, doctor and keyboard configuration commands, and the HTTP server for an agent on another machine.

### Conventions

`mirroir-mcp` with no command is the MCP server. `mirroir-mcp --help` lists the commands, and `mirroir-mcp --version` prints the version. Every command behaves the same way:

- `--help` or `-h`, anywhere on the line, prints that command's usage and exits 0 without running anything.
- An option the command does not define is refused by name with exit code **2**, and nothing runs. Options are never abbreviated: `--dry-ru` is refused, not read as `--dry-run`.
- Exit code **1** means the command ran and failed. Exit code **0** means it succeeded.
- Output is plain text unless it goes to a terminal. `--no-color` and a non-empty `NO_COLOR` turn colors off in a terminal as well. `mirroir-run` follows the same rule.

### Recorder

Record a walk by hand and emit it as a replayable iOS scenario — the same
`.mirroir/apps/<app>/scenarios/<flow>.ios.yaml` that `generate_skill … emit=true`
writes, declared in `SAMPLE.md` and the plan:

```bash
mirroir record --app Calculator --name calculator-add --output-dir ~/code/my-repo
```

The app is reset and launched first, so the walk starts where its replay
starts. Tap, long-press, swipe and type on the mirrored phone, then press
Ctrl+C. Each interaction is stored with the OCR text of the screen it acted on,
so taps replay by label and each screen a tap reaches gets a `wait_for:`.

- `--app` and `--name` are required; `--name`'s slug names the scenario file.
- `--output-dir` is the consumer repo root; without it the nearest `.mirroir/`
  above the working directory is used (`~/.mirroir` is refused).
- Every session is saved first to
  `~/.mirroir-mcp/recordings/<app>/<flow>.recording.json`. When the emit is
  refused — a tap OCR could not name, say — the error names the step and the
  recording is kept.
- `--from-recording <file>` re-renders a saved recording without the device
  (the file names its own app and flow, so `--app`/`--name` are refused with it).
- `--no-ocr` is refused: a walk without OCR names no element for any tap.

### Doctor

Verify your setup:

```bash
mirroir doctor
mirroir doctor --json    # machine-readable output
```

### Configure

Set up your keyboard layout for non-US keyboards:

```bash
mirroir configure
```

iPhone Mirroring forwards physical keys, and the iPhone turns them into characters with its own hardware-keyboard layout. `keyboardLayout` names that layout, so `type_text` presses the key that produces each character there — on `Canadian-CSA`, `/` is the key left of `Z`, not US QWERTY's `/` key (which types `é`). Set it in `settings.json` or with the `IPHONE_KEYBOARD_LAYOUT` environment variable; it must match the layout chosen on the iPhone under Settings › General › Keyboard › Hardware Keyboard:

```jsonc
// .mirroir-mcp/settings.json
{ "keyboardLayout": "Canadian-CSA" }   // or "com.apple.keylayout.Canadian-CSA"; "" or "US" = US QWERTY
```

A character the layout types with a dead key (`ê` is `^` then `e` on Canadian-CSA) is typed as that key pair. A character the layout has no keys for (emoji, CJK, `<` on Canadian-CSA) goes through the clipboard, which needs Universal Clipboard.

### Window capture

`mirroir-mcp ax-capture <name> [--out <dir>] [--watch <seconds>]` saves what Accessibility reports for the iPhone Mirroring window as a tagged test fixture. It reads only; nothing is pressed. See [Testing](testing.md#capturing-the-mirroring-window) for when to use it and what to check before committing a capture.

### Serve

By default mirroir-mcp talks to one MCP client on standard input and output and opens no network port. `mirroir-mcp serve` is for the other case: the agent runs on another machine and the phone is next to your Mac.

```bash
mirroir-mcp install-agent                 # writes the LaunchAgent and creates the token
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.mirroir.serve.plist
```

The agent then serves MCP over HTTP at `http://127.0.0.1:8765/mcp`. It listens on loopback only, so from the other machine you forward the port and point the client at the forward:

```bash
ssh -N -L 8765:127.0.0.1:8765 you@your-mac
claude mcp add --transport http mirroir http://127.0.0.1:8765/mcp \
  --header "Authorization: Bearer <contents of ~/.mirroir-mcp/serve-token on the Mac>"
```

Any client that speaks MCP Streamable HTTP and can send a fixed `Authorization` header works the same way. Both the `2026-07-28` revision and the `2025-11-25` `initialize` handshake are served. Each message is one POST answered with one JSON object: there is no event stream and no session, so a long call such as `generate_skill` holds its connection until it finishes, and the next call waits behind it. A client that gives up and disconnects while its call waits has that call dropped; it is not run later.

`serve` takes these options:

| Option | Meaning |
|---|---|
| `--port <n>` | Port to listen on. Default 8765. |
| `--token-file <path>` | File holding the bearer token. Default `~/.mirroir-mcp/serve-token`. It must be a regular file that only you can read (`chmod 600`), with at least 32 characters. |
| `--allow-origin <origin>` | Accept requests whose `Origin` header is this value, for a non-browser client that sends one. Repeatable. A page in a browser cannot call the server either way: no CORS preflight is answered. |

What to know before relying on it:

- **Permissions are the same file.** `serve` reads `permissions.json` as the stdio server does: `.mirroir-mcp/` in the directory it was started from, then `~/.mirroir-mcp/`. launchd starts the agent in `/`, so the agent uses the one in your home; started by hand inside a project, `serve` uses that project's. It refuses `--dangerously-skip-permissions`. With no file, only the read-only tools are served.
- **Why a LaunchAgent.** Screen capture and input belong to the Mac's login session. launchd starts the agent inside that session; a command typed into an SSH shell runs outside it. `install-agent` only writes the file and prints the two `launchctl` commands; it starts nothing.
- **The Mac must be logged in and unlocked, with iPhone Mirroring connected.** Mirroring stops when the Mac's screen locks, so this is for a Mac that stays awake next to the phone, not for an unattended one.
- **Do not use it at the same time as a local MCP client from the same install.** macOS gives screen capture to one process per executable: two servers started from the same `mirroir-mcp` binary and called back to back both answer "Failed to capture/analyze screen". Use one or the other, or stop the agent (`launchctl bootout gui/$(id -u)/dev.mirroir.serve`) while you work locally.
- **Screen Recording and Accessibility must be granted to the agent.** Under launchd no terminal or editor stands in front of mirroir-mcp, so the grants the stdio server uses do not carry over. Which entry macOS lists for it, and whether the grants survive an upgrade, has not been measured yet: check both panes in System Settings › Privacy & Security after the first `status` call, and read `~/.mirroir-mcp/serve.log`.
- **`install-agent` refuses a copy run through npx**, whose path changes with each version. Install with Homebrew first. `install-agent --print` shows the plist without writing anything.
- **To stop and remove it:** `launchctl bootout gui/$(id -u)/dev.mirroir.serve`, then delete `~/Library/LaunchAgents/dev.mirroir.serve.plist` and `~/.mirroir-mcp/serve-token`.

Read [Security](security.md#network-exposure) before turning this on: whoever holds the token controls the phone.
