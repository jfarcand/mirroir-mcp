# mirroir-mcp

Let your agent use your real iPhone: errands across your apps, automations, even games.

No Developer Mode, no Xcode, no WebDriverAgent, no jailbreak. mirroir-mcp works through macOS iPhone Mirroring, from any MCP client.

This npm package downloads the pre-built macOS binary from [GitHub releases](https://github.com/jfarcand/mirroir-mcp/releases) and checks it against the release's SHA-256 checksum.

## Requirements

- An Apple Silicon Mac on macOS 15 or later
- An iPhone connected through [iPhone Mirroring](https://support.apple.com/en-us/120421)

## Install

```bash
npx -y mirroir-mcp install    # or: brew tap jfarcand/tap && brew install mirroir-mcp
npx -y mirroir-mcp doctor     # names anything left to fix
```

Or add it to your MCP client config yourself:

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

Only read-only tools are exposed until you allow more in [`permissions.json`](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/permissions.md).

See the [full documentation](https://github.com/jfarcand/mirroir-mcp#readme) and [every install path](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/install.md).

## License

Apache-2.0
