# mirroir for Hermes Agent

Lets Hermes use your real iPhone through macOS iPhone Mirroring: it reads the screen as text with tap points, then taps, types, swipes and opens apps. The phone stays stock.

This package is a portable Agent Plugins package: three data files and no code. Hermes 0.23.0 installed it with the command below, passed it through `hermes plugins validate`, started the server and listed its tools.

## Install

    hermes plugins install jfarcand/mirroir-mcp/plugins/hermes --enable

Start a new chat afterwards. Needs Hermes 0.21.6 or later with its MCP support installed (the `mcp` extra: without it Hermes lists the skill but starts no MCP server), macOS 15 or later with iPhone Mirroring connected, and Node.js (the server starts with `npx`). Grant Screen Recording and Accessibility to the app that runs Hermes; `npx -y mirroir-mcp doctor` names the app and the pane.

## What you get

- The `mirroir` MCP server; its tools appear as `mcp__mirroir__<tool>`.
- The skill `mirroir:mirroir`, the operating manual the agent follows.
- An approval prompt before every tool call that can change the phone, because the server is declared `untrusted` and every such tool says it is not read-only. Reading the screen does not ask.

## Allow it to act

The server fails closed: until you create `~/.mirroir-mcp/permissions.json`, only read-only tools are listed. Hermes's one-shot mode (`hermes -z`) skips its approval prompts, so there the permission file is the only gate. See [Permissions](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/permissions.md).

## What it runs, sends and fetches

- Runs `npx -y mirroir-mcp@<version>`, pinned to this package's version: one local process on standard input and output, no network port.
- npm downloads the package. Its install step downloads the matching prebuilt binary from this project's GitHub releases and refuses it unless its SHA-256 matches the release's checksum file.
- At most once a day the server asks registry.npmjs.org for the newest version (`"updateCheck": false` in `~/.mirroir-mcp/settings.json` turns that off). It never replaces itself.
- Screenshots and screen text go to the model Hermes uses. No accounts, no analytics.

[Security](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/security.md) · [Privacy](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/privacy.md)
