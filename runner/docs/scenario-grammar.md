# Scenario grammar reference

This document is the canonical reference for the YAML grammar `mirroir-run`
parses. Every `SkillStep` variant is listed below with the YAML shape and its
dispatch target (process / http / web / oracle / unwired). Which run path
exercises a step end-to-end depends on the invocation flag
(`--sample` / `--validate` / `--run-scenario` / `--emit playwright` /
`--diff-text`).

Source of truth: `runner/src/parser/step.rs`. Run `cargo doc --open` from
`runner/` for the auto-generated rustdoc; this file gives the prose view
keyed by scenario-author concerns.

## Top-level shape

```yaml
version: 1                  # schema major; mismatch is a hard load error
name: "scenario name"
description: "free-form prose"   # optional
app: "spring-boot-chat"          # optional; references SAMPLE.md slug
tags: ["smoke", "streaming"]     # optional
drift:                           # optional; the scenario layer of the drift hierarchy
  fingerprint_similarity:    { min: 0.90 }
  judge_score_swing:         { max_delta: 0.05 }
  response_levenshtein_pct:  { max: 0.20 }
  step_latency_pct_increase: { max: 0.25 }
steps:
  - <step>
  - <step>
```

`${VAR}` and `${VAR:-default}` substitution runs over the raw YAML *before*
parsing. POSIX semantics — unset or empty variables resolve to the default
when one is given, else to the empty string.

In `--sample` mode the runner additionally exposes `${MIRROIR_SAMPLE_DIR}`
so scenarios can reference baseline files relative to the sample directory.

The `drift:` block declares only the metrics this scenario wants to own; every
other metric falls through to the sample's `APP.md` `drift_defaults:` block and
then to the `drift-defaults.yaml` on the search path. A metric no layer
declares fails the run by name rather than defaulting — see the README's
"The three verdicts" section.

---

## Process target steps (dispatched via `tokio::process`)

### `spawn`

Start a subprocess. `command:` or `from: SAMPLE.md` is required; inline values
win over manifest values when both are present.

```yaml
- spawn:
    id: server                       # required; later kill/assert_log/wait_port reference this id
    command: "java -jar foo.jar"     # required unless `from:` is set
    from: SAMPLE.md                  # optional; pulls boot.command / cwd / env / timeout_s from SAMPLE.md
    cwd: "samples/foo"               # optional; resolved relative to the sample dir in --sample mode
    env:                             # optional; merged with manifest env (inline wins per-key)
      SPRING_PROFILES_ACTIVE: ci
    timeout_s: 60                    # optional ceiling on subprocess runtime
    expect_exit: 0                   # optional required exit code (post-mortem check)
    capture_stdout: var_name         # optional; capture stdout into a runner variable
```

Errors: `DuplicateProcessId`, `SpawnMissingSource`, `ProcessSpawn`.

### `kill`

Terminate a previously-spawned subprocess. Graceful: waits `grace_s` for
natural exit, then SIGTERM, then SIGKILL.

```yaml
- kill: { id: server, grace_s: 5 }   # cleanup: optional shell command after exit
```

Errors: `UnknownProcess`, `ProcessControl`.

### `wait_port`

Block until a TCP port reaches the expected state. Both loopback addresses are
probed — IPv4 `127.0.0.1` **and** IPv6 `[::1]` — so dev servers that bind only
one are detected either way (Vite, for example, binds `[::1]` when told to
listen on `localhost`). `expect: open` resolves once either connects; `expect:
closed` once both refuse.

```yaml
- wait_port: { port: 8081, timeout_s: 30, expect: open }   # expect: open|closed
```

Errors: `WaitPortTimeout`.

### `assert_log`

Auto-polling regex match against the subprocess's captured stdout+stderr.
Mirrors Playwright's "expect-with-retry" model — polls every 100 ms up to
`timeout_s` (default 5 s).

```yaml
- assert_log:
    id: server
    pattern: 'Started ServerApplication'
    flags: "i"           # optional: i (case-insensitive), m, s, x, U
    timeout_s: 10        # optional
```

Errors: `UnknownProcess`, `RegexFlags`, `RegexCompile`, `LogAssertion`.

### `assert_log_clean`

Single-shot scan: fail if any `deny` pattern matches a line that no `allow`
pattern also matches.

```yaml
- assert_log_clean:
    id: server
    deny:
      - { pattern: '^\s*ERROR\b', flags: "im" }
      - { pattern: 'BeanInstantiationException' }
    allow:
      - { pattern: 'Disabled retry on ERROR\.RATE_LIMIT' }
```

---

## HTTP target step (dispatched via `reqwest`)

### `http`

REST probe with optional status + body substring assertions.

```yaml
- http:
    method: GET                              # GET|POST|PUT|DELETE|HEAD|PATCH
    url: "http://127.0.0.1:8081/api/info"
    expect_status: 200                       # optional
    expect_body_contains:                    # optional list of substrings
      - "webtransport"
      - "websocket"
    timeout_s: 30                            # optional per-request timeout (default 30)
```

Errors: `HttpClient`, `HttpRequest`, `HttpStatusMismatch`, `HttpBodyRead`, `HttpBodyMismatch`.

---

## Web target steps (dispatched via Playwright)

A scenario compiles to **exactly one** `npx playwright test` invocation. Every
web step of the scenario lands in that one spec, in file order; runner-side
steps before it are pre-hooks and runner-side steps after it are post-hooks.

That model requires the web steps to form **one adjacent run**. A scenario that
resumes web work after a runner-side step (`web → http → web`) is rejected by
`--validate` and by the run, naming the offending step index
(`WebBlockNotContiguous`). The shape cannot mean what it reads: the trailing
web steps would execute in the same browser context as the leading ones,
before the step the file puts between them. A second `target:` to force a
second invocation is worse — a fresh context silently discards cookies,
`localStorage`, auth, in-memory JS state and open WebSockets. Move the
runner-side step before or after the web run instead.

`remember:` is exempt: it records a note and drives nothing, so it is
transparent to the run and may sit anywhere — see [Annotation
step](#annotation-step).

### `target`

Declares the web surface for the scenario's web run. One per scenario, as the
first step of that run — both rules are enforced by `--validate` and by the
run, because a second declaration compiles to nothing and a late one would let
web steps execute before the page is navigated.

```yaml
- target:
    kind: web                                       # the only kind mirroir-run executes
    browsers: [chrome, firefox, webkit]             # default [chrome]
    url: "http://localhost:8081/"                   # initial navigation
```

`kind` parses `web|process|http|ios|macos`, but `web` is the only one this
binary opens a run for; every other kind is refused by name at validate time.
`ios` and `macos` are mirroir-mcp's surfaces — the Swift MCP server drives the
device. Subprocess and REST scenarios declare **no** `target:` at all: their
work is carried by the `spawn:` / `kill:` / `http:` steps, which dispatch in
Rust and read nothing from a surface declaration.

### `tap`, `type`, `wait_for`, `assert_visible`, `assert_not_visible`

Click a labelled element / write text into one / wait for label / assert
visibility. A label resolves in three ways, in priority order:

1. **Raw CSS / locator passthrough** — label starts with one of `[ # . : > *`
   → `page.locator(label)`. Use for form fields and attribute selectors:
   `[name="email"]`, `[placeholder^="Type a message"]`, `.message--assistant`.
2. **Playwright locator-engine passthrough** — label starts with `role=`,
   `text=`, `xpath=`, `css=`, `id=`, or `data-testid=` → `page.locator(label)`.
   This is the workhorse for accessible apps (ARIA role + accessible name):
   `role=button[name="Send message"]`, `role=heading[name="Settings"]`.
3. **Otherwise** → one `.or()` union in Playwright's own locator priority:
   `getByRole('button', { name, exact })` → `getByRole('link', …)` →
   `getByLabel` → `getByPlaceholder` → `[data-test="<label>"]` →
   `getByText(<label>, { exact: true })`. Matching two different elements in
   that union is a strict-mode error, which is the intended signal: an
   ambiguous label is an authoring bug.

Each of the four verbs takes a string shorthand or a record. The record adds
`last: true` (select the final match of an ambiguous label instead of
requiring a unique one) and `timeout_s` (per-step ceiling; the emitter's
default is 30s). `assert_visible` / `assert_not_visible` also take
`contains:`, which upgrades the assertion from presence to content
(`toContainText`, negated for `assert_not_visible`).

`type:` compiles to `locator.fill()` — it clears the field and writes the
text, so a re-run against a pre-filled form produces the same value an empty
one did. The shorthand writes into the element the closest preceding `tap:` /
`long_press:` touched; `into:` names the target explicitly. With neither, it
writes into whatever holds focus (`page.locator(":focus")`).

```yaml
- tap: "role=button[name=\"Send message\"]"          # role engine (preferred for real apps)
- tap: "[name=\"email\"]"                            # raw CSS for inputs
- type: "hello mirroir"                             # fills the element the tap above touched
- type: { text: "hello", into: "prompt-input", timeout_s: 5 }
- tap: { label: "message-agent", last: true }       # the newest bubble, not a unique one
- wait_for: { label: "text=claude-opus", timeout_s: 60 }  # text= = substring; survives version bumps
- assert_visible: "role=heading[name=\"Directory listing for /\"]"
- assert_visible: { label: "message-agent", contains: "4", last: true }
- assert_not_visible: "Error toast"
- assert_not_visible: { label: "status", contains: "Error" }
```

Selector gotchas (each surfaced by real onboarding):

- **`role=…[name="X"]` matches the accessible name EXACTLY** (trimmed,
  case-insensitive) — not a substring. It won't match an element whose
  accessible name is a longer concatenation (e.g. a card `<button>` whose name
  is title + description). Target the unique inner text node instead (bare
  text → `getByText`, which the click bubbles up), or use `text=`.
- **`text=` is a substring match**; bare text (no prefix) is **exact** via
  `getByText`. A label with a trailing count/badge ("Pending Users (3)") needs
  `text=Pending Users`, not the bare exact form.
- **Duplicate matches** (label resolves to >1 element → Playwright strict-mode
  error) → append `>> nth=0`: `role=button[name="Create Group"] >> nth=0`.
- Trust the accessible name from a browser **accessibility tree** snapshot, not
  `el.textContent` — they differ (e.g. a tab reads `Pending 3` with a space in
  the a11y name even when `textContent` is `Pending3`).

Every compiled spec also installs two browser-side invariants no scenario has
to ask for: an uncaught exception (`pageerror`) or a failed response for a
resource the page depends on (`document`, `script`, `stylesheet`, `fetch`,
`xhr`) fails the test. They are the browser counterpart of `assert_log_clean`,
and they ride out on the `mirroir-captures` attachment as `page_errors` and
`failed_requests` so the failure carries the detail.

### `press_key`

Key combos with mirroir-style modifier names (mapped to Playwright's
`Meta+Shift+Enter` form at compile time).

```yaml
- press_key: { key: "return", modifiers: ["command", "shift"] }
```

### `swipe`, `scroll_to`, `long_press`, `drag`

```yaml
- swipe: "up"                                       # up|down|left|right; parks the pointer, then page.mouse.wheel
- scroll_to: "Welcome"
- long_press: { label: "Send", duration_ms: 1000 }
- drag: { from: "card-1", to: "drop-zone" }
```

### `screenshot`, `open_url`

```yaml
- screenshot: "after-send"                          # writes screenshots/after-send.png
- open_url: "https://example.com/profile"
```

`screenshot:` shoots the live page, so it is a web step wherever it reads: one
placed after a `kill:` is rejected as a split web run, because by then there is
no page worth shooting.

---

## Annotation step

### `remember`

Records the author's observation on the run. It needs no browser, no page and
no runner-side state, which is why it is neither a web step nor a runner-side
step: it never opens a web run and never ends one, so it is legal at any
position — including after the `kill:` that tears the server down.

```yaml
- remember: "Verified streaming reply over preferred transport"
```

Inside a web run it rides along and reaches the emitted spec as a comment at
its own position. Anywhere else the runner dispatches it and logs the note.
Either way it asserts nothing, so a scenario whose only step is a note still
fails with `ScenarioNothingEvaluated`.

---

## Native-only steps (iOS / macOS via mirroir-mcp Swift)

The Rust runner does not execute these. They parse so cross-platform
scenarios stay portable; in `mirroir-run` they are no-ops (logged as
"step kind not yet wired"). The Swift `mirroir-mcp` binary dispatches them
on iOS/macOS targets.

```yaml
- launch: "Expo Go"
- home: null
- shake: null
- reset_app: "com.example.app"
- set_network: "airplane"
```

---

## `measure`

Times an action against a visibility outcome. Compiles into the scenario's
Playwright spec: the action runs, the clock stops when `until` becomes visible,
and the elapsed milliseconds ride out on the `mirroir-captures` attachment. The
Rust post-hook enforces `max_seconds` against that number
(`MeasureBudgetExceeded`), and fails the scenario when the invocation recorded
no timing at all (`MeasureNotCaptured`).

```yaml
- measure:
    name: "first_token_latency"                     # key the latency is filed under
    action: "tap:send"                              # <verb>:<value> — tap|type|press_key|swipe|open_url|wait_visible
    until: "streaming-caret"                        # stops the clock when this becomes visible
    max_seconds: 5                                  # optional ceiling; also the wait timeout
```

`until` is optional when the action is itself a waiting verb. `wait_for` and
`wait_visible` are self-terminating, so the action's own label stops the clock
and there is nothing to wait for afterwards — the step times how long that label
takes to appear:

```yaml
- measure:
    name: "first_token_latency"
    action: "wait_visible: streaming-caret"         # the wait IS the measured operation
    max_seconds: 5
```

Any other verb omitting `until` is a compile-time `PlaywrightUnsupported`: a
`tap` has nothing to stop the clock, and guessing a stop condition would time
the wrong thing. A verb with no web equivalent is likewise a compile-time
failure, not a silently skipped step.

`max_seconds` is an absolute budget; the *relative* question — did this get
slower than last time? — is the `step_latency_pct_increase` drift metric, which
compares the recorded latency against `.harness/last-green.json`. Blowing the
budget is a FAIL; creeping past the increase ceiling is a DRIFT. The runner asks
both.

---

## Control-flow steps

### `condition`

Branch on visibility of a label. The runner does **not** yet dispatch
condition; it parses for grammar compatibility.

```yaml
- condition:
    if_visible: "Invalid credentials"
    then:
      - tap: "Sign Up"
    else:
      - wait_for: "Welcome"
```

### `report`

Declare the scenario's verdict. All four forms are honored:

| Form | Effect |
|---|---|
| `pass`, `cross_surface_pass` | the step counts as an evaluation and the run stays green |
| `fail` | `RunnerError::ScenarioReportedFailure` — the run exits 1 |
| `drift` | files a `declared` candidate on the scenario's drift session; the run exits 65 and the remaining post-hooks still execute |

```yaml
- report: pass                                       # or fail | drift | cross_surface_pass
- report: { verdict: drift }
```

The JSON report artifact is separate and always written: `--report` (default
`mirroir-run-report.json`) carries the run summary regardless of this step.

---

## Oracle steps

### `judge`

LLM scoring of a captured response. See [judge-profiles.md](judge-profiles.md)
for the profile registry.

```yaml
- judge:
    profile: byte-stable                             # fast-ci | byte-stable | cheap-local
    user_prompt_template_hash: "sha256:abc123…"      # pinned; verified every run, hard-fails on mismatch
    response_selector: "[data-test=reply]"           # scraped from the live page into the captures attachment
    pass_threshold: 0.85
    pass_threshold_tolerance: 0.05                   # optional; effective = threshold - tolerance
    expected_signal: "summary covers transports"     # human-readable; not load-bearing
    response_text: "…"                               # optional: overrides the scrape
    response_file: "${MIRROIR_SAMPLE_DIR}/captured.txt"   # optional: overrides the scrape
    response_drift:                                  # optional; the innermost drift layer
      max_levenshtein_pct: 0.15                      # overrides response_levenshtein_pct for this step
    drift_baseline_file: "${MIRROIR_SAMPLE_DIR}/baselines/judge.txt"   # optional; overrides last-green
```

The response resolves in this order: `response_text`, then `response_file`,
then the page. A judge step placed after the scenario's web run compiles a
scrape of `response_selector` at its own position in the flow; the text is
filed under the step's index in the `mirroir-captures` attachment and read back
by the post-hook. A judge step with none of the three available fails with
`OracleError::Decode` naming the selector it wanted.

Every judge step feeds the scenario's drift session: its score and its response
are recorded in `.harness/last-green.json` on a green run, and compared against
that store on the next one. A score below `pass_threshold - tolerance` is a
FAIL; a score that held while the wording moved is a DRIFT, and the run
continues so `kill:` and `assert_log_clean:` still execute.
`drift_baseline_file` names the text this step drifts from instead of the
store; `response_drift.max_levenshtein_pct` is the innermost layer of the
threshold hierarchy for `response_levenshtein_pct`. Under `mirroir-run accept`
the baseline file is rewritten with what the run judged rather than read — see
[drift-and-accept.md](drift-and-accept.md).

Errors: `OracleError::{UnknownProfile, MissingApiKey, Transport, Decode,
BelowThreshold, TemplateMismatch, ThresholdUnspecified}`.

### `cross_surface`

Pairwise equivalence check across N captured response files (one per
surface). Uses Jaccard fingerprint similarity over normalized token sets.

```yaml
- cross_surface:
    response_files:
      - "${MIRROIR_SAMPLE_DIR}/baselines/surface.web.txt"
      - "${MIRROIR_SAMPLE_DIR}/baselines/surface.ios.txt"
    min_similarity: 0.5                              # required
    capture:                                         # optional: produce the web baseline
      selector: "[data-test=surface]"                #   scrape this selector's innerText()
      to: "${MIRROIR_SAMPLE_DIR}/baselines/surface.web.txt"  #   into this file (one of response_files)
```

With `capture`, the compiled spec scrapes `selector`'s text at the step's own
position in the flow and files it in the `mirroir-captures` attachment (the
same channel `judge:` uses); the post-hook writes it to `to`. The web baseline
is produced at run time rather than hand-authored. Without `capture`, all
`response_files` must already exist. A declared capture that the attachment
never carried fails the step (`CrossSurfaceNotCaptured`) rather than comparing
a stale file.

`capture.selector` goes through the compiled spec's `_by` helper, the same one
every locator step uses: anything opening `[`, `#`, `.`, `:`, `>` or `*` reaches
`page.locator` as raw CSS, and a bare word is looked up as a role / label /
placeholder / `data-test` / visible text. A bare element name like `main` is not
a label, matches none of those, and resolves to nothing.

`to` **must** be one of the `response_files`, and the step fails when it is not:
a capture aimed elsewhere writes text nothing reads, leaving the comparison to
run against whatever sits at the listed path — a stale baseline from an earlier
run compares clean and the check passes for the wrong reason.

`min_similarity` is **required** — the threshold is the gate, and a scenario
that never declared one holds the run to nothing. A listed file that
fingerprints to no tokens (blank, whitespace, or punctuation only) is refused
before any pair is scored: two empty surfaces score a perfect match, so a check
over them would pass without evidence.

A surface this runner drives no executor for is named `<flow>.ios.txt`, flat
under the sample's `baselines/`. That spelling is the contract, not a
convention: `--sample` accounts for every `baselines/*.ios.txt` and refuses a
sample committing one no scenario compares — see
[sample-md-format.md](sample-md-format.md). A capture spelled any other way is
outside that guard, so an orphan of it rides along green.

Errors: `CrossSurfaceTooFewFiles`, `CrossSurfaceCaptureTargetNotListed`,
`CrossSurfaceNotCaptured`, `CrossSurfaceEmptySurface`, `CrossSurfaceMismatch`.

---

## Step kind ↔ dispatch target

| Step kinds | Dispatcher | Notes |
|---|---|---|
| `spawn`, `kill`, `wait_port`, `assert_log`, `assert_log_clean` | `target::process` (tokio) | Per-scenario `ProcessRegistry`; shared in `boot_once` mode |
| `http` | `target::http` (reqwest) | One `HttpClient` per scenario |
| `target` (kind=web), `tap`, `type`, `wait_for`, `assert_visible`, `assert_not_visible`, `screenshot`, `press_key`, `swipe`, `scroll_to`, `long_press`, `drag`, `open_url`, `measure` | `compile::playwright` + `compile::invoke` | One spec, one `npx playwright test` per scenario |
| `remember` | annotation | Neither surface: a comment in the spec when it sits inside the web run, a logged note when it sits outside. Never splits the run. |
| `judge` | `oracle::judge` | OpenAI-compatible chat completions |
| `cross_surface` | `oracle::drift` | Jaccard over `Fingerprint` |
| `report` | `replay_step` | Applies the declared verdict to the scenario. |
| `launch`, `home`, `shake`, `reset_app`, `set_network`, `condition` | unwired | Parse and skip; logged. iOS-side dispatched by `mirroir-mcp` (Swift) when the scenario also runs there. |
