# Security

## What This Tool Does

This gives an AI agent full control of your iPhone screen. It can tap anything, type anything, open any app — autonomously. That includes banking apps, messages, and payments.

## Kill Switch

mirroir can act only through a live iPhone Mirroring session, and four things end it at once:

- **Quit iPhone Mirroring.** An app the server saw running and then gone is never reopened by the agent: `status` and every input say it was quit and that only you can open it again. (The server does open the app once, in the background, when it was not running when the server started and an agent's first action needs it.)
- **Pick up the iPhone and unlock it.** Mirroring disconnects while the phone is in use and cannot reconnect until it is locked again.
- **Lock the Mac's screen.** Mirroring stops with it.
- **End the server.** Quit the MCP client that started it; for the `serve` agent described below, `launchctl bootout gui/$(id -u)/dev.mirroir.serve`.

By default nothing runs in the background: the server lives and dies with the MCP client that started it. The one exception is the `serve` agent, which you install yourself and which keeps running until you remove it.

## Network Exposure

By default the MCP server communicates exclusively via stdin/stdout with the MCP client. It opens no network port and listens on no socket, so remote access is not possible.

`mirroir-mcp serve` is the opt-in exception. It is never started for you: not by the installers, not by the plugins, not by the server itself. When you run it:

- **It listens on `127.0.0.1` only.** There is no option to bind another address. To reach it from another machine you forward the port over SSH (`ssh -N -L 8765:127.0.0.1:8765 you@your-mac`), so the traffic travels inside your SSH session.
- **Every request needs a bearer token.** The token is 32 random bytes kept in `~/.mirroir-mcp/serve-token`. `serve` refuses to start if that file is a symlink, belongs to another user, or is readable by anyone but you. The token is never printed or logged.
- **A browser cannot call it.** Any request carrying an `Origin` header is refused with 403 unless you named that origin with `--allow-origin`. That option is for non-browser clients that send an `Origin`; the server answers no CORS preflight, so a page in a browser cannot call it even from an allowed origin.
- **The permission file still decides.** Over HTTP the tools are the ones `permissions.json` allows, read exactly as on stdio (`.mirroir-mcp/` in the directory `serve` was started from, then `~/.mirroir-mcp/`; the LaunchAgent starts in `/`, so it uses the one in your home). `serve` refuses `--dangerously-skip-permissions`: there is no way to open every tool to a token holder from the command line.
- **One tool call runs at a time**, in the order the requests arrived, as on stdio. A call whose client disconnects while it waits its turn is dropped, not run late against a screen that has changed.
- **Nothing is read from a caller without the token.** Path, method, origin and token are judged from the headers; the body of a refused request is never read.

What this does not protect against, stated plainly:

- **Whoever holds the token controls the phone** within what `permissions.json` allows: messages, purchases, anything those tools can reach. The server asks for no per-action approval; consent is whatever the remote agent's host enforces.
- **The token is static.** It has no scope and no expiry. To rotate it, delete the file, run `mirroir-mcp install-agent` again, restart the agent and update your client.
- **Any process running as you can read the token file**, and any local process of any user can connect to the port; only the token stops it.
- **The client cannot tell who answers on the port.** If the agent is not running, another local user's process can listen on the same port and collect the token from the next request. This design assumes a Mac you do not share.
- **The connection is plain HTTP.** That is safe on loopback and inside an SSH forward. Do not put it behind a proxy that exposes it without TLS: the token and every screenshot would cross the network in clear text.
- **Screen contents leave the Mac.** Screenshots and screen text, including one-time codes and messages, go to wherever the remote agent runs.
- **A LaunchAgent is persistent background access.** Once installed it starts at every login until you run `launchctl bootout gui/$(id -u)/dev.mirroir.serve` and delete `~/Library/LaunchAgents/dev.mirroir.serve.plist`. It runs from its own app bundle, `~/.mirroir-mcp/mirroir serve.app`, which holds its own Accessibility and Screen Recording grants under the name "mirroir serve": removing the agent does not remove them, so turn them off in Privacy & Security too.
- **The bundle is signed with a certificate in your login keychain.** `install-agent` creates a self-signed code-signing certificate, "mirroir serve local signing", so the grants hold across upgrades. macOS grants them to whatever bundle with the identifier `dev.mirroir.serve` that certificate signs: any process running as you can use the key to sign other code under that identifier and inherit both grants. A process running as you can already read the token and drive the agent, so this adds no access, but delete the certificate when you remove the agent.

The [kill switch](#kill-switch) is the same as on stdio: unlock the iPhone, lock the Mac, or stop the agent. See [CLI tools](cli.md#serve) for setup.

## No Root Required

The MCP server runs as a regular user process. All input is delivered via the macOS CGEvent API, which requires only Accessibility permissions — no root privileges, no daemons, no kernel extensions.

## Fail-Closed Permissions

Without a config file, only the 13 read-only tools (`screenshot`, `describe_screen`, `status`, etc.) are exposed. Mutating tools (`tap`, `type_text`, `launch_app`, etc.) are hidden from the MCP client entirely — it never sees them unless you explicitly allow them.

The config loader checks the project-local directory (`<cwd>/.mirroir-mcp/permissions.json`) first, then the global directory (`~/.mirroir-mcp/permissions.json`). A malformed config is treated as no config: the loader logs a warning and falls back to read-only defaults, so a broken file fails closed rather than opening everything up.

Beyond the `allow` whitelist, the config supports:

- **`deny`** — a blocklist that overrides `allow`. A tool in `deny` is refused even if it is also in `allow` (or if `allow` is `"*"`).
- **`perApp`** — per-app `allow`/`deny` rules layered on top of the global lists during exploration of a named app. A per-app `deny` blocks a globally-allowed tool; a per-app `allow` opens a globally-denied tool. Useful for locking down typing or URL opening while exploring a sensitive app.
- **`skipElements`** — element text patterns the explorer must never tap (case-insensitive containment).
- **`blockedApps`** — app names `launch_app` refuses to open.

To bypass all permission gating, pass `--dangerously-skip-permissions` (alias `--yolo`) on the command line; this exposes every tool regardless of config.

See [Permissions](permissions.md) for configuration details and examples.

## Recommendations

- **Use a separate macOS Space** for iPhone Mirroring to isolate it from your work.
- **Configure `blockedApps`** to prevent the AI from opening sensitive apps (banking, payments).
- **Start with a narrow allow list** — only enable the tools your workflow actually needs.
- **Review skills before running them** — `get_skill` shows the full skill content before execution.
