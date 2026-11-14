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
mirroir doctor --fix     # walk through each missing permission
mirroir doctor --grants  # check only the two permissions
```

Each permission hint names what macOS checks the grant against: the process it holds *responsible* for the server. A terminal or an editor answers for what it starts, so a server started from iTerm needs iTerm turned on. Claude starts its servers through a helper that disclaims responsibility, so each one answers for itself and the pane lists **mirroir-mcp** (the Claude extension's `mirroir-mcp.app`, or the bare binary); `check_health` run inside that client names it. The serve agent answers for itself as "mirroir serve".

`--fix` takes the missing grants one at a time, Accessibility first: it says which app to turn on, opens the pane in System Settings, and waits (up to `grantWaitUs`, five minutes) until a newly started `mirroir-mcp doctor --grants` sees the switch on, because a running process keeps its old Screen Recording answer until it restarts. It then says which app to quit and reopen. Run from a terminal, it checks the terminal's grants.

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
mirroir-mcp install-agent                 # writes the LaunchAgent and its app bundle, creates the token
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
- **The Mac must be logged in and unlocked, with iPhone Mirroring connected.** Measured on macOS 26.5: once the screen locks, `status` says "the Mac's screen is locked" and asks for it to be unlocked; capture keeps working for about 30 seconds, then fails until the Mac is unlocked, and recovers on its own after. This is for a Mac that stays awake next to the phone, not for an unattended one.
- **The agent runs from its own app bundle.** `install-agent` copies the binary into `~/.mirroir-mcp/mirroir serve.app`, with an Info.plist and the robot icon, signs it, and the LaunchAgent runs that copy. So macOS lists the agent as "mirroir serve" with its icon, and because its path differs from the Homebrew one, a local stdio client and the agent can capture at the same time (measured: seven captures alternating between the two, all answered).
- **Screen Recording and Accessibility must be granted to "mirroir serve".** Under launchd no terminal or editor stands in front of mirroir-mcp, so the grants the stdio server uses do not carry over. Measured on macOS 26.5: the first `status` call raises an Accessibility dialog and the first capture a Screen Recording one, both naming "mirroir serve"; click Open System Settings, not Deny (Deny records a refusal and macOS does not ask again), and turn it on in Privacy & Security › Accessibility and in Screen & System Audio Recording. Restart the agent after the Screen Recording grant: `launchctl kickstart -k gui/$(id -u)/dev.mirroir.serve`. Until both are on, `status` says "No window" and capture fails; `check_health` names the pane. macOS may also skip the dialog and list "mirroir serve" switched off, or not list it at all: then turn it on, or add it with + (the folder is hidden: press ⌘⇧. in the file picker to see `.mirroir-mcp`). macOS also lists the agent under General › Login Items & Extensions › Allow in the Background, as "mirroir serve", "Item from unidentified developer", with a generic icon (only an app signed by an Apple developer team gets its own there); that entry lets it run and is not a privacy grant.
- **The grants survive upgrades because of the signature.** macOS ties each grant to the signature of the app it was given to, not to its name. `install-agent` signs the bundle with a self-signed certificate, "mirroir serve local signing", which it creates in your login keychain the first time and reuses after; the grant then names that certificate, which every later build meets. Measured on macOS 26.5: with both grants given, a bundle rebuilt from a different build and signed again kept both, with no dialog. The first signing asks whether codesign may use the key; choose Always Allow and later installs sign silently. The certificate is trusted by nothing else and signs nothing but this bundle. After upgrading mirroir-mcp, run `install-agent` again (the agent keeps running the copy it was given) and restart the agent.
- **A bundle from an earlier install-agent was signed ad hoc**, and macOS pinned its grants to that one build: measured, a rebuilt ad-hoc bundle lost both, and turning the switch off and on keeps the old pin. `install-agent` says so when it replaces one; remove the old entries once with `tccutil reset All dev.mirroir.serve`, restart the agent, and turn "mirroir serve" on again in both panes.
- **`install-agent` refuses a copy run through npx**, whose path changes with each version. Install with Homebrew first. `install-agent --print` shows the plist without writing anything.
- **To stop and remove it:** `launchctl bootout gui/$(id -u)/dev.mirroir.serve` (measured: the port closes at once), then delete `~/Library/LaunchAgents/dev.mirroir.serve.plist`, `~/.mirroir-mcp/mirroir serve.app` and `~/.mirroir-mcp/serve-token`, remove "mirroir serve" from both privacy panes (`tccutil reset All dev.mirroir.serve`), and delete the certificate "mirroir serve local signing" from the login keychain. `uninstall-mirroir.sh` does all of it.

Read [Security](security.md#network-exposure) before turning this on: whoever holds the token controls the phone.
