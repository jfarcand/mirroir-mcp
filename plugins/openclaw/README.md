# mirroir for OpenClaw

Lets an [OpenClaw](https://docs.openclaw.ai) agent use your real iPhone through macOS iPhone Mirroring: it reads the screen as text with tap points, then taps, types, swipes and opens apps. The phone stays stock.

This package is an OpenClaw plugin: it brings the mirroir MCP server, the operating manual as a skill, and an approval gate in front of every call that can change the phone.

## Install

From a checkout of this repository:

    openclaw plugins install --link ./plugins/openclaw

Needs OpenClaw 2026.10.9 or later, an Apple Silicon Mac on macOS 15 or later with iPhone Mirroring connected, and Node.js (the server starts with `npx`). Grant Screen Recording and Accessibility to the app that runs the OpenClaw Gateway; `npx -y mirroir-mcp doctor` names the app and the pane.

## What you get

- The `mirroir` MCP server, declared in `openclaw.plugin.json`. Its tools appear as `mirroir__<tool>`. An entry named `mirroir` under `mcp.servers` in your OpenClaw config replaces it, as for any plugin server.
- The skill `mirroir`, the operating manual the agent follows.
- An approval gate, a `before_tool_call` hook (`approval.js`):
  - Reading the screen does not ask: `describe_screen`, `screenshot`, `listen` and the other read-only tools in `read-only-tools.json`.
  - Every other mirroir call asks you first. The prompt shows the whole call, the tool and its arguments, with invisible and direction-changing characters spelled out. A call too long to show whole is refused, never cut.
  - A sender OpenClaw knows is not the owner is refused before any prompt, because a chat can answer its own approvals. A requester OpenClaw does not identify still gets the prompt.
  - **Allow always** covers that tool for the rest of the session. It lives in the Gateway's memory: a restart or a new session asks again.
  - No answer within five minutes, a denial, or a cancelled prompt sends nothing.

## Allow it to act

The server fails closed: until you create `~/.mirroir-mcp/permissions.json`, only read-only tools are listed, so there is nothing to approve. The approval gate is a second check, not a replacement. See [Permissions](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/permissions.md).

## Tool profiles and sandboxes

OpenClaw's `coding` and `messaging` tool profiles include configured MCP servers. A sandboxed session gets the tools only when `tools.sandbox.tools` names `bundle-mcp`, the plugin id `mirroir`, or the tools themselves. See OpenClaw's [tool policy](https://docs.openclaw.ai/gateway/config-tools/tool-policy).

## What it runs, sends and fetches

- Runs `npx -y mirroir-mcp@<version>`, pinned to this package's version: one local process on standard input and output, no network port.
- npm downloads the package. Its install step downloads the matching prebuilt binary from this project's GitHub releases and refuses it unless its SHA-256 matches the release's checksum file.
- At most once a day the server asks registry.npmjs.org for the newest version (`"updateCheck": false` in `~/.mirroir-mcp/settings.json` turns that off). It never replaces itself.
- Screenshots and screen text go to the model OpenClaw uses. No accounts, no analytics.

## Development

`npm test` (or `node --test` in this directory) runs the gate's tests; no OpenClaw is needed. The Swift test `OpenClawPackageTests` keeps `read-only-tools.json`, the skill file and the version pins in step with the server.

[Security](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/security.md) · [Privacy](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/privacy.md)
