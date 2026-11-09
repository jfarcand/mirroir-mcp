# mirroir

Let Claude use your real iPhone through macOS iPhone Mirroring, then replay what it did without an LLM. Claude reads the screen with on-device OCR, taps, swipes, types and opens apps. The phone stays stock: no Developer Mode, no Xcode, no jailbreak, and nothing to install on it.

## Install

```
/plugin install mirroir --marketplace jfarcand/mirroir-mcp
```

## Requirements

- macOS 15 or later, with an iPhone connected through [iPhone Mirroring](https://support.apple.com/en-us/120421)
- Node.js, because the plugin starts the server with `npx`
- Screen Recording and Accessibility permissions for the app that runs the server; macOS asks on first use

## Allow it to act on the phone

The server fails closed. Until you allow more, Claude only gets read-only tools such as `describe_screen`, `screenshot` and `status`. To let it act, create `~/.mirroir-mcp/permissions.json`:

```json
{
  "allow": ["tap", "swipe", "type_text", "launch_app"],
  "blockedApps": ["Your Bank"]
}
```

Once tools that act are allowed, Claude can tap and type in any app you have not blocked, including messages and payments. Claude is told to ask you before sending, buying, deleting or changing a setting. The kill switch is unlocking the iPhone, locking the Mac's screen, or quitting Claude; quitting the iPhone Mirroring app is not one, because the next action reopens it. See [Permissions](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/permissions.md) and [Security](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/security.md).

## What it runs, sends and fetches

- **Runs:** `npx -y mirroir-mcp@<version>`, pinned to the plugin's version. It starts one local process that talks to Claude over stdin and stdout and opens no network port.
- **Downloads:** npm fetches the package, whose install step downloads the matching prebuilt binary from this project's GitHub releases.
- **Update check:** at most once a day it asks `registry.npmjs.org` for the newest version. Turn this off with `updateCheck: false` in the settings.
- **Sends to Claude:** screenshots and screen text you ask it to read. These can show whatever is on your phone, so close anything you would not share.
- **Optional, off until you configure it:** some features, such as playing a game from screenshots, can call an AI provider you set up, such as Anthropic or OpenAI, and send it screenshots and screen text. An element-detection model is downloaded only from a URL you set.
- **Stores:** settings, skills, the update-check result and any models in `~/.mirroir-mcp`. There are no accounts and no analytics.

## Learn more

[Documentation](https://github.com/jfarcand/mirroir-mcp) · [Website](https://mirroir.dev) · [Issues](https://github.com/jfarcand/mirroir-mcp/issues) · [Privacy](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/privacy.md)

Licensed under Apache-2.0.
