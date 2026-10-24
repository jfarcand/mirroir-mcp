# Security

## What This Tool Does

This gives an AI agent full control of your iPhone screen. It can tap anything, type anything, open any app — autonomously. That includes banking apps, messages, and payments.

## Kill Switch

The MCP server only works while iPhone Mirroring is active. Closing the iPhone Mirroring window or locking the phone kills all input immediately. No persistent background access is possible.

## Network Exposure

The MCP server communicates exclusively via stdin/stdout with the MCP client. It does not open any network ports or listen on any sockets. Remote access is not possible.

## No Root Required

The MCP server runs as a regular user process. All input is delivered via the macOS CGEvent API, which requires only Accessibility permissions — no root privileges, no daemons, no kernel extensions.

## Fail-Closed Permissions

Without a config file, only the 12 read-only tools (`screenshot`, `describe_screen`, `status`, etc.) are exposed. Mutating tools (`tap`, `type_text`, `launch_app`, etc.) are hidden from the MCP client entirely — it never sees them unless you explicitly allow them.

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
