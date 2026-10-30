# Web and iOS in one scenario

How `mirroir-mcp` (the Swift MCP server that drives an iPhone) and `mirroir-run` (the
Rust scenario runner) work together, and what a single scenario can check across a browser
and a phone.

## Who does what

| Binary | Drives | Runs on |
|---|---|---|
| `mirroir-mcp` | the iPhone, through iPhone Mirroring: taps, typing, OCR | macOS |
| `mirroir-run` | web pages (through Playwright), subprocesses, HTTP; plans the scenario and judges the result | macOS and Linux |

`mirroir-run` never touches the phone itself. When a scenario opens a
`target: { kind: ios }` block, the runner writes that block to a file and hands it to
`mirroir-mcp test`, which drives the phone and writes a report the runner reads back.

## A scenario is hooks and device blocks

A `target:` step opens a **device block**. The block carries the device steps that follow
it and ends at the first runner-side step. Everything outside a block is a **hook**, run in
Rust in file order.

```yaml
version: 1
name: the delivery panel says the same thing on web and on iPhone
steps:
  - target: { kind: web, browsers: [chrome], url: "http://localhost:18902/parity.html" }
  - assert_visible: "parity-panel"                 # web block: one Playwright run
  - target: { kind: ios, app: "Safari" }
  - wait_for: { label: "Delivery confirmed", timeout_s: 20 }   # ios block: one mirroir-mcp run
  - cross_surface:                                 # hook: compares what both blocks captured
      captures:
        - { surface: web, selector: "[data-test=parity-panel]", to: "${MIRROIR_SAMPLE_DIR}/baselines/live.web.txt" }
        - { surface: ios, to: "${MIRROIR_SAMPLE_DIR}/baselines/live.ios.txt" }
      response_files:
        - "${MIRROIR_SAMPLE_DIR}/baselines/live.web.txt"
        - "${MIRROIR_SAMPLE_DIR}/baselines/live.ios.txt"
      min_similarity: 0.5
```

The rules, checked by `mirroir-run --validate` before anything runs:

- At most **one block per surface**. A second web block would start a fresh browser and lose
  the first one's cookies and state, so it is refused.
- A block's steps are **adjacent**. A device step after a runner-side step that already ended
  its block is refused, naming the step.
- An iOS block carries the interaction steps (`tap`, `type`, `wait_for`, `assert_visible`,
  `scroll_to`, `long_press`, `drag`, `measure`, …) plus the phone-only ones: `launch`, `home`,
  `shake`, `reset_app`, `set_network`.
- Web-only options inside an iOS block (`last:`, `into:`, `contains:`, a per-step `timeout_s:`
  on `tap` or an assertion) are refused by name, never silently dropped.

## Comparing the two surfaces

A `cross_surface:` step compares files by token overlap (Jaccard similarity) and fails below
`min_similarity`. Its `captures:` produce those files during the run:

- a **web** capture scrapes `selector`'s text from the page;
- an **ios** capture is the iOS block's final screen, read by mirroir-mcp's OCR, and takes no
  selector.

Each capture is written to its `to` before the comparison, so the run that checks the gate is
the run that produced both halves. A mismatch is a failure (exit 1). `mirroir-run accept`
re-records every captured file and names any compared file it did not write.

On the real device this has been checked with desktop Chromium against iPhone Safari on the
same page: similarity 0.74 passed, and pointing the web side at a reworded page dropped it to
0.11 and failed.

## What the hand-off looks like

For an iOS block, `mirroir-run`:

1. writes the block in mirroir-mcp's one-step-per-line format to
   `target/mirroir-ios/<sample>/<scenario>/ios-block.yaml`;
2. runs `mirroir-mcp test --report-json <dir>/ios-report.json --capture ios <block file>`;
3. reads the report — the same Playwright JSON-reporter shape it reads from a web block — for
   the verdict, the failing step, `measure:` timings, and the final-screen capture.

A failure names the step inside the block, e.g.
`mirroir-mcp: 1 of 1 test cases failed — step 2 (wait_for: "Delivery confirmed"): Timed out`.
If `mirroir-mcp` exits without writing the report (it refused the file, or iPhone Mirroring
is not connected), the run fails with its stderr — never a pass.

## Requirements

| For | You need |
|---|---|
| web blocks | Node and `@playwright/test` with its browsers — see [`runner/docs/playwright-setup.md`](../runner/docs/playwright-setup.md); point `MIRROIR_PLAYWRIGHT_HOME` at the install |
| iOS blocks | macOS, iPhone Mirroring connected, and `mirroir-mcp` on `PATH` or named by `MIRROIR_MCP_BIN` |

On Linux, a scenario with an iOS block is refused with `IosNeedsMacosHost`. Web, process and
HTTP scenarios run anywhere.

## Getting an iOS flow into `.mirroir/`

`generate_skill` with `emit: true` (on `finish` or `explore`) writes a runnable iOS leg into
the consumer repo's `.mirroir/apps/<app>/`:

- `scenarios/<flow>.ios.yaml` — the captured walk (`finish`) or each interesting explored path
  (`explore`) as a `target: { kind: ios }` block. Every flow opens `reset_app: "<App>"` then
  `launch: "<App>"`: a launch of a running app resumes wherever it was left, and the walk was
  recorded from the app's root. That own-app reset right before its launch is the one
  `reset_app` `mirroir-mcp test` runs without `--confirm-destructive`; any other `reset_app`
  still needs it. A tap is followed by a `wait_for:` when the
  screen it reached shows, on arrival, a landmark the screen before did not; a tap on a row the
  explorer found by scrolling is preceded by a `scroll_to:` on that row. The emitter owns these
  files: re-emitting a flow overwrites it;
- `SAMPLE.md` declaring every flow under `must_pass`;
- a `must_pass` entry in `.mirroir/mirroir.yaml`.

`SAMPLE.md` and `mirroir.yaml` are created with an ownership marker on their first line, and
later emits — the next goal of a session, another `explore` — insert their flows and apps into
the existing `session.scenarios.must_pass` and `plan.must_pass` lists in place. Every other
byte is kept: a `boot` the web leg filled in (`cwd`, ports, timeout), `nice_to_pass`, `name`,
`description`, keys after the list, comments. When that list cannot be located unambiguously —
missing, repeated, written flow-style (`[a, b]`) or empty — the emit is an error result carrying
the lines to paste rather than a guess. A flow counts as declared only as an entry of the fenced
yaml block's `session.scenarios.must_pass` or `nice_to_pass` list — a commented-out entry or a
path mentioned in prose does not; one declared only under `nice_to_pass` is named in the result,
since its FAIL does not fail the sample. Delete the marker to own the file: the emitter then
never writes it, and a flow it does not declare makes the emit an error result carrying the
exact lines to paste under `must_pass` and the flows dropped as unreplayable (the scenarios,
`APP.md` and plan entry are written before that check). A human-owned `mirroir.yaml` gets the
plan entry to paste in the result.

A path the runner could not replay faithfully — an AI-only step such as `remember:`, a tap with
no label, a label OCR never read (an icon-only tab) — is dropped by name, with its reason, in
the result; the other flows are still emitted. An `emit: true` call is an error result when no
flow is left to write, when the exploration did not finish, or when a human-owned `SAMPLE.md`
does not declare a written flow. An `APP.md` for the app whose `version:` is missing or
unsupported is not used, and the `explore`/`finish` result says which file and why — an
`explore` that skips a playable game or fails to launch the app included.
The emitter writes no `baselines/*.ios.txt`: an iOS capture is produced by the run, through a
`cross_surface:` step's `surface: ios` capture.

Run `mirroir-run` from the repo on a Mac with the phone connected and it replays the flow. To
check the web app against the same screen, copy the iOS block into the web scenario and end it
with a `cross_surface:` step as above.

## How the contract stays honest

- Swift's report writer is pinned byte for byte to a fixture the runner's ingest tests read,
  so a format change on either side fails a test on that side.
- The emitter's output for a synthetic Clock walk is committed under
  `runner/tests/fixtures/emitted/`. A Swift test regenerates it byte for byte; Rust tests load
  it through the runner's own loaders, plan it, render every step for mirroir-mcp and run it as
  a sample against a stub `mirroir-mcp`.
- CI's `Build` workflow runs `runner/samples/ios-fixture` through both binaries against
  FakeMirroring and fails unless the log shows the hand-off, the capture, the comparison and a
  passing verdict.
- The same workflow explores the Clock pack on FakeMirroring with `generate_skill` (`emit: true`)
  and replays what it wrote with `mirroir-run --sample`. It fails unless every emitted step
  passed in mirroir-mcp and a `tap:` and a `wait_for:` crossed to the device.

## Current limits

- The two blocks run **one after the other**, not at the same time. Parallel lanes, waiting on
  a streaming app's events, and an LLM judge of whether two answers mean the same thing are part
  of the design but not built.
- `keyboardLayout` must match the phone's hardware-keyboard layout. A mismatch garbles typed
  URLs (for example `/` arriving as `é` on a `Canadian-CSA` phone with no layout set), so an
  `open_url:` step fails there.
- `macos` window targets are driven by `mirroir-mcp test` directly; `mirroir-run` does not open
  a block for them.

## Reference

- Step grammar: [`runner/docs/scenario-grammar.md`](../runner/docs/scenario-grammar.md)
- `.mirroir/` plan and cross-surface pairing: [`runner/docs/mirroir-dotfile.md`](../runner/docs/mirroir-dotfile.md)
- `accept` and drift: [`runner/docs/drift-and-accept.md`](../runner/docs/drift-and-accept.md)
- The runner's own README: [`runner/README.md`](../runner/README.md)
