# Changelog

What changed for you in each release. Full notes, with every commit, are on [GitHub Releases](https://github.com/jfarcand/mirroir-mcp/releases).

## Unreleased

- **macOS 27: input reaches the iPhone again** ([#84](https://github.com/jfarcand/mirroir-mcp/issues/84)). On macOS 27.3, taps, keys and swipes were reported as done but never arrived. On any macOS newer than 26, mirroir now uses HID input, which brings iPhone Mirroring to the front. The `windowInput` setting (`auto`, `on`, `off`) forces either path, and `mirroir-mcp doctor` shows which one is in use.
- **`tap` says when nothing changed.** When the screen reads the same before and after a `tap(text:)`, the reply says so, instead of a silent pass.
- **`launch_app` works with iOS 27's Spotlight**, which opens as a bare search field and shows its top hit without a heading.
- **`launch_app` never opens the App Store for an app that is not installed.** It refuses when Spotlight's top hit is a store card with a Get button, and waits for the results to settle before pressing Return.
- **`blockedApps` covers more routes.** `open_url` (Safari) and `set_network` (Settings) are refused when their app is blocked.

## 0.49.0 (2026-11-15)

- Swipes slower than a flick move the content exactly as far as the finger, with no inertia; a fast swipe still flicks.
- Two mirroir processes no longer steal each other's screen capture.
- Pasted text and Spotlight launches are checked on screen.
- A Stage Manager or Mission Control thumbnail no longer sets the window size ([#83](https://github.com/jfarcand/mirroir-mcp/issues/83)).

## 0.48.0 (2026-11-14)

- Fixes for `launch_app`, `listen`, `press_home`, targets, `doctor` and the Claude Desktop bundle.
- `press_home` reports a screen Home leaves unchanged as likely Home, not failed.

## 0.47.0 (2026-11-12)

- **`listen`**: hear what the phone plays (a reel's narration, a voice message), transcribed on the Mac. Needs macOS 26.
- `npx mirroir-mcp` works with npm 12.

## 0.46.0 (2026-11-11)

- **Breaking:** `scroll_to`'s `direction` names where the content is, not the finger's direction. Compiled skills move to version 6; recompile older ones.
- `mirroir-mcp serve` drives the phone over HTTP from another machine, behind a token.
- Hermes Agent plugin; `get_notes` and `save_note` keep lessons per app.
- Quitting iPhone Mirroring is a stop: the agent never reopens it.

## 0.45.0 (2026-11-06)

- Swipes no longer take your Mac's front app or move the pointer.
- Fast swipes page video feeds such as TikTok.
