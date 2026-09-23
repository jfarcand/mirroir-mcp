# Web fixture — hermetic static pages for the web leg

A dependency-free static site the runner boots the same way `mega-sample` does:
`python3 -m http.server` over a directory of plain HTML. No framework, no build
step, no network. Every page is deterministic so a scenario's failure is always
the runner's fault, never the fixture's.

The pages exist to give the web leg the shapes real apps hand it:

| Page | Shape it provides |
|---|---|
| `login.html` | a login form — `data-test` inputs, a submit button, a rendered result |
| `counter.html` | a counter whose value changes when acted on — a real state delta to assert |
| `ambiguity.html` | the same visible label on three elements — strict-mode ambiguity |
| `renamed.html` | `data-test="place-order"` — the baseline attribute name |
| `renamed-variant.html` | the identical page with `data-test="submit-order"` — the renamed attribute |
| `cookie-banner.html` | a declarative obstacle that covers the primary action until dismissed |
| `console-error.html` | throws an uncaught error on load — a dirty console with a clean-looking DOM |
| `summary.html` | an order confirmation in prose — the baseline wording a judge scores |
| `summary-reworded.html` | the identical page whose confirmation is worded differently — the DRIFT case |
| `parity.html` | a delivery panel whose text is one half of a cross-surface parity gate |
| `parity-reworded.html` | the identical page whose panel says the same thing in other words — the parity break |

`obstacle.js` implements the obstacle concept in plain HTML + JS: a page declares
its obstacles in a `<script type="application/json" id="obstacles">` block with
`id` / `title` / `body` / `buttons` / `trigger`, and the script injects the modal
when the trigger fires. The triggers mirror the ones the iOS simulator honors —
`on_first_load`, `{ "after_clicks": <n> }`, `never` — so a web scenario and an iOS
scenario describe the same obstacle the same way.

```yaml
version: 1
name: web-fixture
description: |
  Static-HTML fixture site. Boots once on port 18902; scenarios share it.
session:
  boot_once: true
  boot_ready_port: 18902
  boot_ready_timeout_s: 15
  boot:
    command: "python3 -m http.server 18902"
    cwd: "public"
  scenarios:
    must_pass:
      - scenarios/login.yaml
      - scenarios/parity.yaml
    nice_to_pass:
      # Needs a judge endpoint (the `byte-stable` profile targets a local
      # Ollama daemon), so it stays out of must_pass — a lane without one
      # would fail on the oracle, not on the fixture.
      - scenarios/order-summary.yaml
```

## The negative scenarios

`scenarios/console-error.yaml` and `scenarios/wrong-selector.yaml` are
**expected to fail**, so they belong to no scenario set — `--sample` would
call the sample red. The CI lane runs each by name and asserts the non-zero
exit, which is what keeps the two failure paths honest:

| Scenario | What it proves |
|---|---|
| `console-error.yaml` | every locator resolves and both assertions hold, and the run still fails — the compiled spec's `pageerror` collector catches the page's uncaught `TypeError` |
| `wrong-selector.yaml` | a locator that names nothing fails with Playwright's own message naming it, and leaves `trace.zip` / `video.webm` / `test-failed-1.png` under `target/playwright/wrong-selector/test-results/` |

Both spawn their own static server (ports 18903 / 18904) rather than the
sample's, so they run standalone:

```bash
cd runner
mirroir-run --run-scenario samples/web-fixture/scenarios/wrong-selector.yaml   # exits 1
```

The spawn's `cwd` is relative to `runner/`; run them from there.

## Serving it by hand

```bash
cd runner/samples/web-fixture/public && python3 -m http.server 18902
```

Then open <http://127.0.0.1:18902/>.

## The drift pair

`summary.html` and `summary-reworded.html` render the same DOM, respond to the
same click, and set the same `data-test` attribute. Only the confirmation's
prose differs. Point `scenarios/order-summary.yaml` at one, let it record a
baseline, then point it at the other: every assertion still passes, the judge
still scores it above threshold, and `response_levenshtein_pct` moves past its
ceiling. That is the DRIFT verdict — exit code 65, a candidate row in
`.harness/drift-log.md`, and the baseline left alone for a human to review.

## The parity pair

`parity.html` and `parity-reworded.html` are the same page for the drift pair's
reason, and `scenarios/parity.yaml` is the cross-surface gate in the shape that
produces its own web half: a `cross_surface:` step at the end of a real web
block, whose `capture:` scrapes the live panel into `baselines/parity.web.txt` —
one of the two files the same step compares.

`baselines/parity.ios.txt` is the other half: the same screen as an iPhone's OCR
reads it, whitespace-joined visible labels including the `Back` / `Orders` chrome
the web page has no equivalent of. It is committed rather than produced, standing
in for what `mirroir-mcp`'s `generate_skill` writes from a connected device.

The two token sets score **0.875**; against `parity-reworded.html` they score
**0.125**. `min_similarity: 0.5` bisects that gap. `parity.web.txt` is written by
every run and is not committed.

A pair below the threshold is a **failure** — exit 1, no `.harness/drift-log.md`
row — not the DRIFT verdict the drift pair above produces. Drift is one surface
moving against its own recorded baseline; this is two live surfaces disagreeing.

`mirroir-run accept` re-records `parity.web.txt` from the live page and warns
that it left `parity.ios.txt` alone — so accepting a reworded page does **not**
close the gate. The next ordinary run refuses again, and the only thing that
closes it is re-capturing the iOS surface on a device. `tests/cross_surface_gate.rs`
pins that sequence.
