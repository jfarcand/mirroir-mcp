# Privacy Policy

Effective November 6, 2026. This policy covers mirroir-mcp and the mirroir plugin, published by Jean-Francois Arcand.

mirroir runs on your Mac. The publisher runs no server for it, has no accounts, collects no analytics, and receives none of your data.

## What mirroir reads

When your AI client calls its tools, mirroir takes screenshots of the iPhone Mirroring window and reads the text in them on your Mac. That can include personal data: names, messages, email addresses, or anything else your phone is showing.

## Where your data goes

- **To your AI client.** Screenshots and screen text go to the MCP client that called the tool, such as Claude Code. That client's own terms and privacy policy decide what happens next, including what it sends to its AI provider.
- **To an AI provider you set up, only if you set one up.** Some features, such as playing a game from screenshots, can call a provider you configure, such as Anthropic or OpenAI, and send it screenshots and screen text. That provider's terms and privacy policy apply. These features stay off until you configure them.
- **To the npm registry, without your screen data.** At most once a day, mirroir asks `registry.npmjs.org` for its newest version. Like any web request, this reveals your IP address to npm. Turn it off with `updateCheck: false` in the settings.
- **To the addresses you choose.** If you set `yoloModelURL`, mirroir downloads a model from it. Installing through npm downloads the package from npm and the matching binary from this project's GitHub releases. Neither download sends your screen data.

## What mirroir stores on your Mac

These stay on your Mac until you delete them:

- settings, permissions, the update-check result and any models, in `~/.mirroir-mcp`
- a debug log, at `~/.mirroir-mcp/debug.log`
- skills you generate or save, which can contain text read from your screen
- screen recordings you start, in the file the tool reports

mirroir does not sync or upload any of them. To remove them, delete the files and `~/.mirroir-mcp`.

## Your controls

- Only read-only tools are available until you allow more in `permissions.json`. See [Permissions](permissions.md).
- `blockedApps` stops `launch_app` from opening the apps you name.
- Closing the iPhone Mirroring window or locking the phone stops all input and capture.

mirroir is not intended for users under 18.

## Contact

Ask questions or report a concern through [GitHub Issues](https://github.com/jfarcand/mirroir-mcp/issues). Changes to this policy appear in this file's [history](https://github.com/jfarcand/mirroir-mcp/commits/main/docs/privacy.md).
