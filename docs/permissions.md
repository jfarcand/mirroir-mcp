# Permissions

The server is **fail-closed by default**. Without a config file, only read-only tools are exposed to the MCP client:

| Always allowed | Requires permission |
|---------------|-------------------|
| `screenshot`, `describe_screen`, `start_recording`, `stop_recording`, `get_orientation`, `status`, `check_health`, `list_scenarios`, `get_scenario` | `tap`, `swipe`, `drag`, `type_text`, `press_key`, `long_press`, `double_tap`, `shake`, `launch_app`, `open_url`, `press_home`, `press_app_switcher`, `spotlight` |

Mutating tools are hidden from `tools/list` entirely — the MCP client never sees them unless you allow them.

## Config File

Create `~/.iphone-mirroir-mcp/permissions.json` (or `<cwd>/.iphone-mirroir-mcp/permissions.json` for project-local overrides):

```json
{
  "allow": ["tap", "swipe", "type_text", "press_key", "launch_app"],
  "deny": [],
  "blockedApps": []
}
```

- **`allow`** — whitelist of mutating tools to expose (case-insensitive). Use `["*"]` to allow all.
- **`deny`** — blocklist that overrides allow. A tool in both lists is denied.
- **`blockedApps`** — app names that `launch_app` refuses to open (case-insensitive).

## Examples

Allow all mutating tools:

```json
{
  "allow": ["*"]
}
```

Allow tapping and typing, block banking apps:

```json
{
  "allow": ["tap", "swipe", "type_text", "press_key", "describe_screen"],
  "deny": ["shake"],
  "blockedApps": ["Wallet", "PayPal", "Venmo"]
}
```

Block Instagram from being launched:

```json
{
  "allow": ["*"],
  "blockedApps": ["Instagram"]
}
```

## CLI Flags

For development and testing, bypass the permission system entirely:

```bash
npx -y iphone-mirroir-mcp --dangerously-skip-permissions
npx -y iphone-mirroir-mcp --yolo   # alias
```

Both flags expose all tools regardless of config. Do not use in production.
