# Changelog

What changed for you in each release. Full notes, with every commit, are on [GitHub Releases](https://github.com/jfarcand/mirroir-mcp/releases).

## 0.50.4 (2026-11-22)

- **Screen reads recover on macOS 27 when Vision's model cache goes away.** A server running for a while could end up failing every read with `e5rtError … 13` until it was restarted. When every read in the server fails, mirroir now reads the screen in a fresh process. The first read after an upgrade or reinstall still takes about 50 s while macOS compiles the model ([troubleshooting](docs/troubleshooting.md)).

- **`mirroir-mcp recognize-text <image>`** prints the text in a PNG or JPEG as JSON. mirroir runs it itself for the recovery above.

- **mirroir-run** drops the unmaintained `chrono` crate for `jiff`, and moves to `url` 2.5.9 for a security fix.

## 0.50.3 (2026-11-19)

- **Swipes move the content again.** Every scroll frame lost its movement before it was sent: a slow drag reached the iPhone as zero, and larger frames were cut short. Drags now page the Home Screen and scroll lists by the distance asked, both when iPhone Mirroring is brought to the front and when input goes straight to its window.

- **A Mac notification elsewhere on screen no longer blocks taps** ([#86](https://github.com/jfarcand/mirroir-mcp/issues/86)). A banner anywhere refused every tap with "A notification is showing over 'iphone'"; now only a banner over the tapped point waits, up to 8 s.

- **OCR reads your Mac's languages by default.** With `ocrLanguages` unset, a Korean or Japanese Mac reads Korean or Japanese screens; codes like `fr` are matched to the ones Vision lists.

- **`mirroir doctor` checks for a newer release every time.** It reused an answer up to a day old, so it could call an outdated version current.

## 0.50.2 (2026-11-18)

- **Driving mode, for a phone on CarPlay.** Add `"driving": { "on": true, "allowedApps": [...] }` to `permissions.json`. While it is on, only the listed apps open, and each input first reads the phone's screen and is refused on a navigation screen; Home and opening a listed app still leave it. It is read on every call, so no restart is needed.

- **Driving mode refuses Dock taps.** Dock icons carry no name, so a tap there could open an app driving mode does not list; open listed apps with `launch_app`.

- **Typing reaches an iOS 27 iPhone again** while your Mac's front app stays in front. Keys sent to the window were dropped on iOS 27; iPhone Mirroring is now told it is active before each typed run, without taking the front.

- **No more false "paused" after typing.** The Mac's autocorrection bubble that pops over the mirroring window (a word with a close button) was read as an interruption, and every following action refused.

- **`type_text` no longer mistakes text already on screen for what it typed.** A typed word that never landed passed when the same word was elsewhere on screen (an icon label behind Spotlight); only text the keys add counts now.

- **Two iPhones with different keyboards on one Mac.** `keyboardLayout` takes a list (`["Canadian-CSA", "US"]`). Text with characters the layouts type with different keys (`'`, `/`, `é`) is pasted until `type_text` gets `keyboard_layout` for the connected phone; the answer is remembered per phone, and one that types what another layout would is forgotten. Older versions read a list as US. Before, one layout for the Mac meant the other phone typed `'` as `<`.

- **An open iPhone Mirroring Settings window no longer blocks input.** It was read as the mirroring window, so `status` said paused and every action refused.

- **`start_recording` keeps recording until `stop_recording`** ([#85](https://github.com/jfarcand/mirroir-mcp/issues/85)). screencapture read the server's own stdin: under `serve` it stopped at once, and over stdio it swallowed the next request. On macOS 15 it also recorded the main display instead of the window; it now records the window's frame there.

- **`tap` by text in Settings hits the row you named.** iOS 26 and 27 Settings end on a search field that read as the Home Screen's, so the tap aimed at an icon above the label and opened the row above (Bluetooth for Cellular). Regression in 0.50.0.

- **`set_network` reads the switch before and after.** It tapped the row's label without reading anything, so `airplane_on` could turn Airplane Mode off, and the Wi-Fi and cellular modes only opened a page while reporting success. It now taps the switch only when it is not already in the asked state, reports what the switch shows afterwards, refuses a row with no switch (cellular data with two SIMs), and finds French labels.

## 0.50.0 (2026-11-16)

- **macOS 27: input reaches the iPhone again** ([#84](https://github.com/jfarcand/mirroir-mcp/issues/84)). On macOS 27.3, taps, keys and swipes were reported as done but never arrived. On any macOS newer than 26, mirroir now uses HID input, which brings iPhone Mirroring to the front. The `windowInput` setting (`auto`, `on`, `off`) forces either path, and `mirroir-mcp doctor` shows which one is in use.
- **`tap` says when nothing changed.** When the screen reads the same before and after a `tap(text:)`, the reply says so, instead of a silent pass.
- **Tapping an app's name on the Home Screen opens it.** `tap` by text goes to the icon above the name; next to a widget it used to land on the name and open nothing.
- **`launch_app` works with iOS 27's Spotlight**, which opens as a bare search field and shows its top hit without a heading.
- **`launch_app` never opens the App Store for an app that is not installed.** It refuses when Spotlight's top hit is a store card with a Get button, and waits for the results to settle before pressing Return.
- **`blockedApps` covers more routes.** `open_url` (Safari), `set_network` (Settings), and a tap, double tap, long press or touch on a blocked app's icon on the Home Screen or in Spotlight are refused before any input.

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
