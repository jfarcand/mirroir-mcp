# Importing Maestro flows

`mirroir-run import maestro` converts [Maestro](https://maestro.dev) flow files
into mirroir-run iOS scenarios, so a flow written for Maestro runs on a real,
stock iPhone through iPhone Mirroring: no Developer Mode, no WebDriverAgent,
no signing.

```bash
mirroir-run import maestro flows/login.yaml flows/settings.yaml \
  -o .mirroir/apps/shop/scenarios \
  --app com.example.shop=Shop
```

Each flow becomes `<out-dir>/<stem>.ios.yaml` (`-o` defaults to the current
directory), with its `runFlow` includes inlined. The command prints one path
per written scenario. Run one with `mirroir-run --run-scenario <file>`, or list
it in a `SAMPLE.md`.

| Flag | Meaning |
|------|---------|
| `-o, --out-dir <DIR>` | Where the scenarios are written (default `.`). |
| `--app <APP_ID>=<NAME>` | The home-screen name Spotlight finds for a bundle id, in the phone's language (`com.apple.mobiletimer=Horloge` on a French iPhone, not `Clock`). Repeatable. |
| `--skip-unsupported` | Import without the commands that have no mirroir equivalent (see below). |

## Nothing is dropped silently

mirroir reads the screen by OCR: iPhone Mirroring exposes no accessibility
tree, so anything Maestro resolves through the view hierarchy (ids, element
state, relational selectors) has no mirroir equivalent. The import never
approximates or drops such an item.

- **Default:** the import fails and lists every unsupported item across all
  flows with its file, line, command and reason. Nothing is written.
- **`--skip-unsupported`:** each one is printed as a warning and recorded as a
  `# skipped (no mirroir equivalent): …` comment where it stood in the
  scenario.

Before a scenario is written it goes back through the runner's own scenario
loader, and must read back as exactly the steps it was built from. Each
command is also checked against the one-step-per-line dialect `mirroir-mcp
test` runs, so a value that dialect cannot carry (a line break, or both quote
characters) is reported as unsupported at import, not at run time.

## The emitted scenario

```yaml
# Imported from the Maestro flow flows/login.yaml by `mirroir-run import maestro`; re-importing overwrites this file.
version: 1
name: "Log in"
tags: ["smoke", "auth"]
steps:
  - target: { kind: "ios", app: "Shop" }
  - reset_app: "Shop"
  - launch: "Shop"
  - tap: "Email"
  - type: "qa@example.com"
  # Focus the password field
  - tap: "Password"
  - type: "${PASSWORD}"
  - press_key: "return"
  - wait_for: { label: "Welcome back", timeout_s: 7 }
  - screenshot: "logged-in"
```

imported from this flow (`runner/tests/fixtures/maestro/login.yaml`):

```yaml
appId: com.example.shop
name: Log in
tags:
  - smoke
  - auth
env:
  EMAIL: qa@example.com
---
- launchApp
- tapOn: "Email"
- inputText: ${EMAIL}
- tapOn:
    text: "Password"
    label: Focus the password field
- inputText: ${PASSWORD}
- pressKey: Enter
- assertVisible: "Welcome back"
- takeScreenshot: logged-in
```

The whole flow is one `ios` block. The first green run records the compiled
screen reference next to it (`<stem>.ios.compiled.json`); later runs fail with
exit 65 when the screens drift from it.

## Header

| Maestro header key | Import |
|---|---|
| `appId` | The app `launchApp` / `stopApp` act on; mapped to a name by `--app`. The `target:` names that app when it is mapped. |
| `name` | The scenario `name` (the file stem when absent). |
| `tags` | The scenario `tags`. |
| `env` | Constants resolved at import time (see Parameters). |
| `onFlowStart` | Its commands run first. Refused in an included flow, since Maestro does not document when an include's hooks run. |
| `onFlowComplete` | Unsupported: it runs even after a failure, and an ios block stops at its first failure. |
| `jsEngine` | Accepted with no effect; every script command is refused. |
| any other key | Unsupported. |

## Parameters

| Maestro | Import |
|---|---|
| `${NAME}`, `NAME` in a header or `runFlow` `env:` | The value, substituted at import. |
| `${NAME}`, `NAME` not in any `env:` | `${NAME}`, which mirroir-run substitutes from the environment when it loads the scenario. Export it where Maestro took `-e NAME=…`. |
| `${NAME \|\| "default"}` | The value when in scope, else `${NAME:-default}`. JavaScript's `\|\|` and the shell's `:-` agree: both take the default for an unset or empty value. |
| any other `${…}` (`${output.x}`, `${A + B}`) | Unsupported: mirroir evaluates no JavaScript. |

A `runFlow` `env:` overrides the caller's constants for the included flow. When
the included flow's own header sets the same name to a different value, the
import refuses it: Maestro does not document which one wins.

mirroir-run substitutes `${NAME}` in the scenario text before parsing it, and
every value the import writes is a double-quoted YAML string, so an
environment value holding `"` or `\` must be escaped for YAML.

## Selectors

A Maestro text selector matches an element when it equals the element's text
or matches it as a regular expression. mirroir finds the text by OCR: exact
first, then case- and diacritic-insensitive, then as a substring.

| Selector | Import |
|---|---|
| `"Login"` / `text: "Login"` | The OCR label `Login`. |
| `".*Save.*"` | The OCR label `Save` (Maestro's "contains", mirroir's substring tier). |
| text holding regex syntax (`.*` or `.+` elsewhere, `[`, `\|`, `^`, `\`, `{`) | Unsupported: it has no literal reading. `.`, `?`, `$`, `(`, `)`, `+` and `*` alone are read literally (`Forgot password?`), and Maestro also accepts an element whose text equals the selector. |
| `id` | Unsupported: ids live in the accessibility tree, which the mirror does not expose. |
| `index` | Unsupported: mirroir taps the best OCR match and has no nth-match selection on iOS. |
| `point` | Unsupported: coordinate taps have no step in the scenario grammar. |
| `enabled`, `checked`, `focused`, `selected` | Unsupported: element state comes from the accessibility tree. |
| `above`, `below`, `leftOf`, `rightOf`, `childOf`, `containsChild`, `containsDescendants` | Unsupported: relational selectors resolve against the view hierarchy. |
| `width`, `height`, `tolerance`, `traits` | Unsupported: they read the view hierarchy. |
| `css` | Unsupported: web pages only. |

## Commands

Every command accepts `label:`, which is written as a comment above its
steps. `optional: true` is unsupported: an ios block fails on a step that does
not succeed, so no step is optional.

| Maestro command | mirroir step |
|---|---|
| `launchApp` | `reset_app` + `launch` (Maestro's default `stopApp: true` restarts the app). `stopApp: false` → `launch` alone. `clearState: true`, `clearKeychain: true`, `permissions`, `arguments` are unsupported. Maestro grants permissions by default; a stock iPhone shows each permission dialog as it would for a user. |
| `stopApp`, `killApp` | `reset_app` (force-quit through the App Switcher). A `stopApp` straight before a `launchApp` of the same app is written once. A `reset_app` not followed by a `launch` of the same app is a destructive step `mirroir-mcp test` asks to confirm. |
| `tapOn` | `tap: <label>`; `repeat: N` → N taps. `delay`, `retryTapIfNoChange: true`, `waitToSettleTimeoutMs` are unsupported. |
| `longPressOn` | `long_press: <label>` (mirroir's press duration). |
| `inputText` | `type: <text>` into the focused field. |
| `eraseText` | `press_key: delete` × N (50 for the bare form, at most 100). |
| `pressKey` | `Enter` → `press_key: return`; `Backspace` → `press_key: delete`; `Home` → `home`. `Lock`, `Power`, `Volume Up/Down` are hardware buttons the mirror does not forward; `Back`, `Tab` and the Android TV remote keys are Android-only. |
| `scroll` | `swipe: up` (the content scrolls down). |
| `swipe` | `direction: UP\|DOWN\|LEFT\|RIGHT` → `swipe: <direction>`. `start`/`end`, `from`, `duration`, `waitToSettleTimeoutMs` are unsupported. |
| `scrollUntilVisible` | `scroll_to: <label>`, for `direction: DOWN` with Maestro's default `timeout` (20000), `speed` (40), `visibilityPercentage` (100) and `centerElement` (false). Any other value is unsupported: `scroll_to` in an ios block scrolls one way with mirroir-mcp's own budget. |
| `assertVisible` | `wait_for: { label, timeout_s: 7 }` — Maestro retries for 7 seconds; mirroir's `assert_visible` checks once. |
| `assertNotVisible` | `assert_not_visible: <label>`. It checks once, so it can fail where Maestro would have waited for the element to go; it never passes where Maestro would fail. |
| `extendedWaitUntil` | `visible:` + `timeout:` → `wait_for` with the timeout in whole seconds, rounded up. `notVisible:` is unsupported, and so is a wait with no `timeout`. |
| `openLink` | `open_url`. `autoVerify: true` and `browser: true` are unsupported. |
| `takeScreenshot` | `screenshot: <name>`. |
| `setAirplaneMode` | `enabled` → `set_network: airplane_on`; `disabled` → `set_network: airplane_off`. |
| `runFlow` | Inlined: a `file:` (relative to the including flow, cycles refused) or inline `commands:`, with its `env:`. `when: { platform: … }` is evaluated at import: iOS runs, any other platform is left out with a comment. Any other `when:` is unsupported. |
| `repeat` | `times: N` → the commands unrolled N times. `while:` is unsupported. |
| `doubleTapOn` | Unsupported: the scenario grammar has no double-tap step. |
| `back` | Unsupported: Android-only; iOS has no system back key. |
| `hideKeyboard` | Unsupported: no step dismisses the iOS keyboard. |
| `waitForAnimationToEnd` | Unsupported: no settle-wait step; use `extendedWaitUntil`. |
| `clearState`, `clearKeychain` | Unsupported: a stock iPhone exposes no reset of one app's data or the Keychain. |
| `toggleAirplaneMode` | Unsupported: the result depends on a state `set_network` cannot read; use `setAirplaneMode`. |
| `evalScript`, `runScript`, `assertTrue` | Unsupported: mirroir evaluates no JavaScript. |
| `copyTextFrom`, `pasteText`, `setClipboard` | Unsupported: mirroir keeps no flow-side clipboard. |
| `inputRandomEmail`, `inputRandomNumber`, `inputRandomPersonName`, `inputRandomText` | Unsupported: pass a value in as a `${VAR}`. |
| `setLocation`, `travel`, `addMedia`, `setPermissions` | Unsupported: a stock iPhone accepts none of these from an automation client. |
| `setOrientation` | Unsupported: no rotation step. |
| `startRecording`, `stopRecording` | Unsupported: no screen-recording step. |
| `assertWithAI`, `assertNoDefectsWithAI`, `extractTextWithAI` | Unsupported: `mirroir-mcp test` has no model inside an ios block. |
| `assertScreenshot` | Unsupported: mirroir compares screens against the scenario's compiled reference instead. |
| `assertDarkMode`, `assertLightMode`, `setDarkMode`, `toggleDarkMode` | Unsupported: no appearance step. |
| `retry` | Unsupported: an ios block runs once and stops at its first failure. |
