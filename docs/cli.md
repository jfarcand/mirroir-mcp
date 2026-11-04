# CLI tools

The recorder, doctor and keyboard configuration commands.

### Recorder

Record a walk by hand and emit it as a replayable iOS scenario — the same
`.mirroir/apps/<app>/scenarios/<flow>.ios.yaml` that `generate_skill … emit=true`
writes, declared in `SAMPLE.md` and the plan:

```bash
mirroir record --app Calculator --name calculator-add --output-dir ~/code/my-repo
```

The app is reset and launched first, so the walk starts where its replay
starts. Tap, long-press, swipe and type on the mirrored phone, then press
Ctrl+C. Each interaction is stored with the OCR text of the screen it acted on,
so taps replay by label and each screen a tap reaches gets a `wait_for:`.

- `--app` and `--name` are required; `--name`'s slug names the scenario file.
- `--output-dir` is the consumer repo root; without it the nearest `.mirroir/`
  above the working directory is used (`~/.mirroir` is refused).
- Every session is saved first to
  `~/.mirroir-mcp/recordings/<app>/<flow>.recording.json`. When the emit is
  refused — a tap OCR could not name, say — the error names the step and the
  recording is kept.
- `--from-recording <file>` re-renders a saved recording without the device
  (the file names its own app and flow, so `--app`/`--name` are refused with it).
- `--no-ocr` is refused: a walk without OCR names no element for any tap.

### Doctor

Verify your setup:

```bash
mirroir doctor
mirroir doctor --json    # machine-readable output
```

### Configure

Set up your keyboard layout for non-US keyboards:

```bash
mirroir configure
```

iPhone Mirroring forwards physical keys, and the iPhone turns them into characters with its own hardware-keyboard layout. `keyboardLayout` names that layout, so `type_text` presses the key that produces each character there — on `Canadian-CSA`, `/` is the key left of `Z`, not US QWERTY's `/` key (which types `é`). Set it in `settings.json` or with the `IPHONE_KEYBOARD_LAYOUT` environment variable; it must match the layout chosen on the iPhone under Settings › General › Keyboard › Hardware Keyboard:

```jsonc
// .mirroir-mcp/settings.json
{ "keyboardLayout": "Canadian-CSA" }   // or "com.apple.keylayout.Canadian-CSA"; "" or "US" = US QWERTY
```

A character the layout types with a dead key (`ê` is `^` then `e` on Canadian-CSA) is typed as that key pair. A character the layout has no keys for (emoji, CJK, `<` on Canadian-CSA) goes through the clipboard, which needs Universal Clipboard.
