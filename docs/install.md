# Install

Every way to install mirroir-mcp, the per-client setup, and how to update or remove it. An agent setting it up should follow [Onboarding](onboarding.md).

## Requirements

- macOS 15+
- iPhone connected via [iPhone Mirroring](https://support.apple.com/en-us/120421)

## Install

The fastest path: paste this into your coding agent (Claude Code, Codex, Cursor, OpenClaw, …) and let it do the setup.

```text
Set up mirroir-mcp so you can drive my iPhone: follow https://github.com/jfarcand/mirroir-mcp/blob/main/docs/onboarding.md step by step, and finish by reading back what my iPhone screen shows.
```

Or install it yourself:

```bash
/bin/bash -c "$(curl -fsSL https://mirroir.dev/get-mirroir.sh)"
```

or via [npx](https://www.npmjs.com/package/mirroir-mcp):

```bash
npx -y mirroir-mcp install
```

or via [Homebrew](https://tap.mirroir.dev):

```bash
brew tap jfarcand/tap && brew install mirroir-mcp
```

or as a [Claude Code plugin](https://docs.claude.com/en/docs/claude-code/plugins):

```
/plugin marketplace add jfarcand/mirroir-mcp
/plugin install mirroir@mirroir
/plugin install skills@mirroir   # optional: the community skill library
```

or from [OpenClaw](https://docs.openclaw.ai), with the skill from [ClawHub](https://clawhub.ai/jfarcand/mirroir):

```bash
openclaw skills install @jfarcand/mirroir
brew tap jfarcand/tap && brew install mirroir-mcp
openclaw mcp add mirroir --command mirroir-mcp
```

or from [Hermes Agent](https://github.com/NousResearch/hermes-agent) 0.21.6 or later, as a plugin that brings the server, the operating manual as a skill, and an approval prompt before every call that can change the phone:

```bash
hermes plugins install jfarcand/mirroir-mcp/plugins/hermes --enable
```

The package is [plugins/hermes](../plugins/hermes/README.md). It is checked in CI against the rules Hermes's loader states, and Hermes 0.23.0 has installed it, started the server and listed its tools: the read-only ones run unasked, every other one asks first. Hermes needs its MCP support (the `mcp` extra) to start the server.

or as an MCP Bundle for Claude Desktop and other MCPB hosts: download `mirroir-mcp.mcpb` from the [latest release](https://github.com/jfarcand/mirroir-mcp/releases/latest) (v0.43.0 and later) and double-click it. The bundle carries the native Apple Silicon binary, so it needs no Node.js. To build one from a release build: `mcpb/build-mcpb.sh .build/release/mirroir-mcp mirroir-mcp.mcpb`.

The first time you take a screenshot, macOS will prompt for **Screen Recording** and **Accessibility** permissions. Grant both. `mirroir doctor` names the app that needs each grant and links the System Settings pane to open.

Every MCP client receives a short operating manual in the server instructions. For the full version as a skill (Claude Code, Codex and OpenClaw), run `npx -y mirroir-mcp skill --install`; `npx -y mirroir-mcp install` does it when it configures either client.

<details>
<summary>Per-client setup</summary>

#### Claude Code

```bash
claude mcp add --transport stdio mirroir -- npx -y mirroir-mcp
```

#### GitHub Copilot (VS Code)

Install from the MCP server gallery: search `@mcp mirroir` in the Extensions view, or add to `.vscode/mcp.json`:

```json
{
  "servers": {
    "mirroir": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "mirroir-mcp"]
    }
  }
}
```

#### Cursor

Add to `.cursor/mcp.json` in your project root:

```json
{
  "mcpServers": {
    "mirroir": {
      "command": "npx",
      "args": ["-y", "mirroir-mcp"]
    }
  }
}
```

#### OpenAI Codex

```bash
codex mcp add mirroir -- npx -y mirroir-mcp
```

Or add to `~/.codex/config.toml`:

```toml
[mcp_servers.mirroir]
command = "npx"
args = ["-y", "mirroir-mcp"]
```

#### Goose

Add to `~/.config/goose/config.yaml`:

```yaml
extensions:
  mirroir:
    name: mirroir
    cmd: npx
    args: [-y, mirroir-mcp]
    enabled: true
    type: stdio
    timeout: 300
```

#### Cline

Open **MCP Servers → Configure → Configure MCP Servers** and add to `cline_mcp_settings.json`:

```json
{
  "mcpServers": {
    "mirroir": {
      "command": "npx",
      "args": ["-y", "mirroir-mcp"],
      "disabled": false
    }
  }
}
```

</details>

<details>
<summary>Install from source</summary>

```bash
git clone https://github.com/jfarcand/mirroir-mcp.git
cd mirroir-mcp
./mirroir.sh
```

Use the full path to the binary in your `.mcp.json`: `<repo>/.build/release/mirroir-mcp`.

</details>

## Updating

`mirroir-mcp update` reads how this copy was installed and upgrades it (`--dry-run` prints the command first). `status`, `check_health` and `mirroir doctor` say when a newer release is out; they ask the npm registry at most once a day, and `updateCheck: false` turns that off. By hand:

```bash
# curl installer
/bin/bash -c "$(curl -fsSL https://mirroir.dev/get-mirroir.sh)"

# npx: npx keeps the copy it cached, so point your MCP config at mirroir-mcp@latest
npx -y mirroir-mcp@latest install

# Homebrew
brew upgrade mirroir-mcp

# From source
git pull && swift build -c release
```

## Uninstall

```bash
# Homebrew
brew uninstall mirroir-mcp

# From source
./uninstall-mirroir.sh
```

If you installed the [`serve` agent](cli.md#serve), stop and remove it as well; `uninstall-mirroir.sh` does this for you, `brew uninstall` does not:

```bash
launchctl bootout gui/$(id -u)/dev.mirroir.serve
rm ~/Library/LaunchAgents/dev.mirroir.serve.plist ~/.mirroir-mcp/serve-token
```
