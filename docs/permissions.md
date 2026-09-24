# Permissions

The server is **fail-closed by default**. Without a config file, only read-only tools are exposed to the MCP client:

| Always allowed | Requires permission |
|---------------|-------------------|
| `screenshot`, `describe_screen`, `start_recording`, `stop_recording`, `get_orientation`, `status`, `check_health`, `list_targets`, `list_skills`, `get_skill`, `calibrate_component` | `tap`, `swipe`, `drag`, `type_text`, `press_key`, `long_press`, `double_tap`, `touch`, `pinch`, `rotate`, `hold_keys`, `multi_touch`, `shake`, `launch_app`, `open_url`, `press_home`, `press_app_switcher`, `press_back`, `spotlight`, `scroll_to`, `reset_app`, `measure`, `set_network`, `switch_target`, `record_step`, `save_compiled`, `generate_skill` |

Mutating tools are hidden from `tools/list` entirely — the MCP client never sees them unless you allow them.

## Config File

Create `~/.mirroir-mcp/permissions.json` (or `<cwd>/.mirroir-mcp/permissions.json` for project-local overrides):

```json
{
  "allow": ["tap", "swipe", "type_text", "press_key", "launch_app"],
  "deny": [],
  "blockedApps": []
}
```

- **`allow`** — whitelist of mutating tools to expose (case-insensitive). Use `["*"]` to allow all.
- **`deny`** — blocklist that overrides allow. A tool in both lists is denied.
- **`blockedApps`** — app names that `launch_app` refuses to open (case-insensitive). `generate_skill(action:"explore")` also honors this list.
- **`skipElements`** — element text patterns the explorer should never tap (case-insensitive containment match). Useful for preventing the explorer from tapping destructive elements like "Delete Account".
- **`perApp`** — per-app tool allow/deny layered on top of the global `allow`/`deny`. Keys are app names (case-insensitive); values are `{ "allow": […], "deny": […] }`. Per-app `deny` overrides global `allow`; per-app `allow` opens tools the global rules would close. Evaluated during `generate_skill` exploration — if an app's `deny` list blocks tools the explorer needs (`tap`, `swipe`, `type_text`, `press_key`), exploration refuses to start.

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

Allow everything, but disable typing and URL-opening while exploring a banking app:

```json
{
  "allow": ["*"],
  "perApp": {
    "Banking": { "deny": ["type_text", "open_url"] }
  }
}
```

## CLI Flags

For development and testing, bypass the permission system entirely:

```bash
npx -y mirroir-mcp --dangerously-skip-permissions
npx -y mirroir-mcp --yolo   # alias
```

Both flags expose all tools regardless of config. Do not use in production.
