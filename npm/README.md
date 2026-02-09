# iphone-mirroir-mcp

MCP server that controls a real iPhone through macOS iPhone Mirroring. Screenshot, tap, swipe, type — from any MCP client.

This npm package downloads the pre-built macOS binary from [GitHub releases](https://github.com/jfarcand/iphone-mirroir-mcp/releases).

## Requirements

- macOS 15+ with iPhone Mirroring
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/) installed and activated
- iPhone connected via iPhone Mirroring

## Install

```bash
npm install -g iphone-mirroir-mcp
```

Then add to your MCP client config:

```json
{
  "mcpServers": {
    "iphone-mirroring": {
      "command": "iphone-mirroir-mcp"
    }
  }
}
```

See the [full documentation](https://github.com/jfarcand/iphone-mirroir-mcp) for setup instructions including the Karabiner helper daemon.

## License

Apache-2.0
