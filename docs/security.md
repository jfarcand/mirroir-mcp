# Security

## What This Tool Does

This gives an AI agent full control of your iPhone screen. It can tap anything, type anything, open any app — autonomously. That includes banking apps, messages, and payments.

## Kill Switch

The MCP server only works while iPhone Mirroring is active. Closing the iPhone Mirroring window or locking the phone kills all input immediately. No persistent background access is possible.

## Network Exposure

The helper daemon listens on a **local Unix socket only** (`/var/run/mirroir-helper.sock`). It does not open any network ports. Remote access is not possible unless the socket is explicitly forwarded.

## Root Daemon

The helper daemon runs as root because Karabiner's HID sockets require root access.

**Socket ownership:** The socket at `/var/run/mirroir-helper.sock` is owned by the console user (the person physically logged in at the Mac) with mode `0600`. Only that user and root can connect. When no console user is detected (e.g. at the loginwindow), the socket is set to mode `0000` (fail-closed — no access until someone logs in).

**Peer authentication:** On each incoming connection, the daemon calls `getpeereid()` to verify the connecting process's UID. Only the console user and root (uid 0) are allowed. All other connections are rejected and closed. The console UID is re-resolved on each connection to handle fast user switching.

## Fail-Closed Permissions

Without a config file, only read-only tools (`screenshot`, `describe_screen`, `status`, etc.) are exposed. Mutating tools (`tap`, `type_text`, `launch_app`, etc.) are hidden from the MCP client entirely — it never sees them unless you explicitly allow them in `~/.mirroir-mcp/permissions.json`.

See [Permissions](permissions.md) for configuration details and examples.

## Recommendations

- **Use a separate macOS Space** for iPhone Mirroring to isolate it from your work.
- **Configure `blockedApps`** to prevent the AI from opening sensitive apps (banking, payments).
- **Start with a narrow allow list** — only enable the tools your workflow actually needs.
- **Review skills before running them** — `get_skill` shows the full skill content before execution.
