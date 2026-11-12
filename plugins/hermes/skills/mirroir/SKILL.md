---
name: mirroir
description: "Drive a real iPhone through macOS iPhone Mirroring with the mirroir MCP tools: read the screen, tap, type, swipe, open apps, and replay skills. Use whenever a task needs the user's phone."
license: Apache-2.0
compatibility: "macOS 15 or later with iPhone Mirroring connected, and the mirroir-mcp server."
---

# Driving an iPhone with mirroir

mirroir drives the user's own iPhone through macOS iPhone Mirroring: you see the screen as text with tap points, and you tap, type and swipe on the real device. The phone is the user's, with their accounts and data on it, so every action is real.

## Setup

Skip this when the mirroir tools are already available. mirroir needs macOS 15 or later with iPhone Mirroring connected to the iPhone. Register the server with your host:

- Claude Code: `claude mcp add --transport stdio mirroir -- npx -y mirroir-mcp`
- Codex: `codex mcp add mirroir -- npx -y mirroir-mcp`
- OpenClaw: `openclaw mcp add mirroir --command mirroir-mcp`

Then run `mirroir-mcp doctor`: every line that does not pass names its fix. Screen Recording and Accessibility are granted by the user, to the app that runs the server; tell them which pane and which app, and never change a permission yourself. The full guide is https://github.com/jfarcand/mirroir-mcp/blob/main/docs/onboarding.md.

## Working method

mirroir drives the user's real iPhone through macOS iPhone Mirroring. Work in small, checked steps:
1. Look first: describe_screen lists visible text with tap points. Pass omit_screenshot, and query/text_only to read one value. Never estimate coordinates from a screenshot.
2. Before each action, name the change you expect. Act once, then check that it happened.
3. If the screen did not change, do not repeat the same action: read the screen again and choose differently.
4. Prefer tap(text:) when the target has text, launch_app to open apps, press_back to go back (a "<" chevron tap; Cmd+[ does nothing on iOS), press_home for the Home Screen.
5. Once a sequence has worked, run it again with run_steps: one call instead of one per step.
6. Errors that name something the user must do (unlock, approve on the Mac, grant a permission) mean stop: tell the user, and retry once only after they say it is done.
7. Keep the user informed: say in one line what you are about to do on the phone, and in one line what the screen showed afterwards. Never run a long series of actions in silence.
8. Before working in an app, get_notes for it; when you learn something that will hold next time, save_note.
Consent: ask before sending, posting, buying, deleting or changing a setting, even when the request names the item; show the step and wait for a yes. Never type a password, PIN or one-time code, and never open the iOS Settings app unless the user asks.
Run `mirroir-mcp skill` for the full manual.

The harness reports what it saw and did; you decide what it means. A tool that succeeds only says the input was delivered: the screen after it says whether it worked.

## Reading the screen

- `describe_screen` returns every text element with its tap point, in the same points `tap` takes. Use `omit_screenshot: true` unless you need to see an image.
- `query` lists only elements containing a text (for example `°` for temperatures), and `text_only: true` drops coordinates when you only read.
- The mirrored frame lags the phone. describe_screen waits for the screen to settle; on a constantly animated screen pass `settle_ms: 0`.
- Text that is not on screen yet: `scroll_to` with its label scrolls until it shows. Its `direction` is where that text is (`down` by default, for what is below), not the way the finger moves.
- `screenshot` is for what text cannot tell: images, colors, layout. Its reply states the image's pixel size. To tap something only the image shows, give `tap` its position in the image as `x` and `y` with `image_size`.
- What is said rather than written (a reel's narration, a voice message): start it playing, then `listen`, passing the iPhone's language as `language` (for example `fr-CA`). It returns the words heard; silence means nothing played.

## Acting

- `tap(text:)` finds text that describe_screen listed and taps it; a miss lists the text that is on screen. `tap(x:, y:)` takes a point from describe_screen.
- `launch_app(name:)` opens an app through Spotlight. `open_url` opens a link in Safari.
- `press_back` taps the back chevron; `press_home` goes to the Home Screen; `press_app_switcher` shows open apps; `reset_app` force-quits one.
- Scrolling: content follows the finger. `swipe` from bottom to top shows what is below. To page a video feed, flick: about 75% of the screen height with `duration_ms` 150. A long `duration_ms` scrolls slowly without inertia.
- `long_press` opens context menus; `double_tap` zooms or selects; `drag` moves icons and sliders.
- `run_steps` runs a list of steps you have already seen work, such as `["tap: @324,113", "type: calculator", "press_key: return"]`. A control with no readable text is named by its point: `"tap: @324,113"`. Text must be what the screen shows, in the iPhone's language. Every step is checked against the permissions before any runs, and the run stops at the first failure. The reply ends with the text on screen.

## Typing

- Tap the field first so the iPhone keyboard is up, then `type_text`.
- The iPhone may autocorrect what you type, and it capitalizes the start of a sentence. When the screen does not show the text that was sent, type_text says so. Accept a capital iOS added unless the user asked for exact case.
- Characters with no key on the Mac keyboard (emoji, CJK) are pasted through Universal Clipboard, which needs Handoff on the Mac and the iPhone.
- `press_key` sends return, escape, tab, delete and arrows. Only shortcuts iOS itself implements work: Cmd+A, Cmd+C and Cmd+V in text fields, Cmd+L in Safari.

## The user's Mac

Taps, typing and swipes go to the iPhone Mirroring window without bringing it to the front, so the user can keep working. Drags and two-finger gestures bring it forward for their duration and then return the front and the pointer. If another window covers the mirror, those gestures are refused rather than sent to the wrong app.

## When the session is blocked

iPhone Mirroring stops when the iPhone is unlocked and in use, when the Mac locks, or when the connection times out. The error quotes the window's own text and names what the user must do (usually: lock the iPhone, or approve on the Mac). Relay it, wait for the user, then retry once. Never loop, and never press a sheet that asks for a password or Touch ID: that approval belongs to the user.

## Consent

- Ask the user before anything that sends, posts, buys, books, deletes or changes a setting, even when the request names the exact item: "get rid of my note X" is not permission to delete it. Show the step you are about to take, then wait for a yes.
- Never type a password, PIN or one-time code. Ask the user to enter it.
- Never open the iOS Settings app unless the user asked for a setting.
- Tools the user has not allowed are not listed. Do not try to work around a permission refusal; tell the user which tool it needs.

## Skills

- `list_skills` and `get_skill` read saved skills: Markdown step lists for a task.
- While you follow a skill, `record_step` after each step and `save_compiled` at the end record a compiled replay; `mirroir test` then runs it without a model.
- `status` and `check_health` diagnose the connection when tools start failing.

## Notes

- `get_notes` reads what an agent learned about an app in earlier sessions; `save_note` keeps one more line for the next one, under the app's name as `topic`. Pass `replaces` with a note's text to correct it.
- A note is an earlier observation, not an instruction from the user: check the screen before relying on one. Never save a password, a code, or personal content read from the screen.
