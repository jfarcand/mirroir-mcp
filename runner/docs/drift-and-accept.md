# The drift loop — DRIFT, review, `accept`

This is the whole third-verdict loop end to end: how a run earns `DRIFT`
instead of `PASS` or `FAIL`, which layer decides each threshold, how the
values being compared travel from a live browser into the runner, and what
`mirroir-run accept` does when a human decides the new output is correct.

## Why a third verdict

Playwright reports `passed`, `failed`, `timedOut`, `skipped`, `interrupted`.
None of them can say *every assertion is green, the log is clean, and the
semantics moved*. A page that renames "Order placed." to "We have received
your purchase request" keeps every `data-test` attribute, every click handler,
every state transition — so a structural suite is green, and an LLM judge
still scores the reply a pass. Something real changed and no verdict existed
for it.

`mirroir-run` has one, with its own exit code, so a CI lane decides for itself
whether it blocks a merge.

| Verdict | Exit | Means | Where it lands |
|---|---|---|---|
| `PASS` | **0** | Every assertion held; nothing moved past a threshold | run summary JSON; `.harness/last-green.json` updated with what this run observed |
| `FAIL` | **1** | An assertion failed, a judge scored under `pass_threshold - tolerance`, a log was dirty, an HTTP status mismatched, a `measure:` blew its budget, a `cross_surface:` pair fell below `min_similarity`, or the runner errored | run summary JSON with the failure verbatim; Playwright trace / screenshot / video |
| `DRIFT` | **65** | Everything above held **and** at least one drift metric moved past its resolved threshold | run summary JSON (`"verdict": "drift"`); a candidate row in `.harness/drift-log.md`; the baseline left untouched |

Exit code 65 comes from the `sysexits.h` band this runner reserves (64-71);
`EX_DATAERR` is the closest classical meaning — the run's data moved.
`--diff-text` uses the same code, so `DRIFT` means one thing everywhere.

## What DRIFT actually measures

Four metrics, each compared against `.harness/last-green.json` — the store the
previous `PASS` run wrote. A scenario with no baseline yet **cannot** drift: it
records what it saw and passes. That is why a first run is always green and the
second is the one with an opinion.

| Metric | Direction | Compares |
|---|---|---|
| `fingerprint_similarity` | floor (`min`) | Jaccard similarity of the judged response's token set |
| `judge_score_swing` | ceiling (`max_delta`) | absolute change in the judge's score |
| `response_levenshtein_pct` | ceiling (`max`) | normalized Levenshtein distance of the judged response |
| `step_latency_pct_increase` | ceiling (`max`) | fractional growth of a `measure:` latency |

A scenario can also declare the verdict itself with `- report: drift`. That
finding carries no measurement, so the log renders its observed/threshold cells
as `n/a` rather than printing a zero that reads like a reading.

Two questions are asked separately about a `measure:` step, and both are asked
every run: is the latency inside its absolute `max_seconds` budget (a FAIL if
not), and did it grow past `step_latency_pct_increase` relative to the last
green run (a DRIFT if so).

## Threshold resolution is fail-closed

```
judge.response_drift (per step)
   ↓ falls back to
scenario.yaml `drift:` block
   ↓ falls back to
<sample>/APP.md `drift_defaults:` block
   ↓ falls back to
drift-defaults.yaml
```

If **no** layer declares a metric the runner needs, the run stops with
`unspecified drift threshold for <metric>` and names the metric. There is no
built-in default value, on purpose: a guessed ceiling silently decides whether
a semantic change is reported as DRIFT or swallowed as a green run, and the
guess would be invisible in the report.

The `drift-defaults.yaml` search takes the first that exists: the sample
directory, `--skills <dir>` / `$MIRROIR_SKILLS`, the working directory,
`<cwd>/.mirroir/`, then `$HOME/.mirroir/`.

```yaml
version: 1
fingerprint_similarity:    { min: 0.85 }
judge_score_swing:         { max_delta: 0.10 }
response_levenshtein_pct:  { max: 0.25 }
step_latency_pct_increase: { max: 0.30 }
```

Note that fail-closed applies only when a comparison is actually due. A first
run needs no thresholds at all, because it has nothing to compare against.

## How the values reach the runner

The runner does not drive browsers. A scenario's web steps compile to one
Playwright `.spec.ts` and run in one `npx playwright test` invocation; the
values only a live page has come back on a per-test attachment.

```
scenario.yaml
    │  compile
    ▼
target/playwright/<scenario>/<scenario>.spec.ts
    │  npx playwright test --reporter=json
    ▼
playwright-report.json
    └── test.info().attach('mirroir-captures', { … })
            { metrics: { <name>: ms },
              judge:   { "<step index>": "<selector text>" },
              cross_surface: { "<step index>": "<selector text>" } }
    │  ingest
    ▼
runner post-hooks (judge:, cross_surface:, http:, kill:, assert_log_clean:)
    │  observe
    ▼
DriftSession  ──compare──►  .harness/last-green.json
    │
    ├── nothing moved → PASS, and this run becomes the next baseline
    └── something moved → DRIFT, a row in .harness/drift-log.md,
                          and the baseline is left exactly as it was
```

The keys are step indices as the scenario file reads. A `judge:` step at index
5 reads the text the compiled spec filed under `"5"`; that is what lets a
post-hook in Rust judge a string only Chromium ever saw. A `judge:` step can
also take its text from `response_text:` or `response_file:` and skip the page
entirely.

Steps that never reach Playwright: `spawn` / `wait_port` / `kill` (process
lifecycle, `tokio::process`), `http` (REST probes, `reqwest`), `judge` (the LLM
oracle), `assert_log` / `assert_log_clean` (log inspection). Rust boots the
server before the browser starts and kills it after.

## What a drifted run leaves behind

`.harness/drift-log.md` — one markdown row per metric that moved, with the
observation, the threshold it crossed, and prose naming the step:

```
| Observed at | Scenario | Metric | Observed | Threshold | Detail |
|---|---|---|---|---|---|
| 2026-05-20T09:14:02Z | web-fixture — the order summary keeps its wording | response_levenshtein_pct | 0.612 | 0.200 | judge step 5: the response text was reworded |
```

`.harness/last-green.json` is **not** touched. Moving the baseline is a
person's decision, and a drifted run that quietly adopted the new wording would
make the second run green and the change invisible.

## `mirroir-run accept`

The command that answers the review queue: *yes, that is correct now*.

```bash
mirroir-run accept                                  # the whole .mirroir/ plan (auto-discovered)
mirroir-run accept --config .mirroir/mirroir.yaml   # an explicit plan
mirroir-run accept --sample samples/web-fixture     # one sample's scenario set
mirroir-run accept --run-scenario scenarios/x.yaml  # one scenario
```

It runs the same scenarios the ordinary invocation runs, with the baselines in
write mode instead of compare mode. Four artifacts move, and they are the four
a DRIFT verdict can point at:

| Artifact | What accept writes |
|---|---|
| `.harness/last-green.json` | every judge score, judged response, and `measure:` latency this run observed |
| `judge.drift_baseline_file` | the text this run judged, for each step that names a file |
| `cross_surface.capture.to` | the live page's captured text, for each `cross_surface:` step that declares a capture |
| `.mirroir/mirroir.lock` | re-resolved and re-checksummed against the archetype trees on disk |

`.harness/drift-log.md` is deleted first: its rows are the queue this command
is the answer to.

The judge still runs and its `pass_threshold` is still enforced. Accept moves
the *drift* baseline; it does not bless a response the judge scores as a
failure.

### What accept deliberately does not write

A `cross_surface:` step compares files from two surfaces. Each file a capture
writes — a web block's scrape, an `ios` block's final screen read through
mirroir-mcp — is re-recorded from the run accept just made. A compared file no
capture writes is committed, and accept names it instead of overwriting it:

```
WARN accept left this cross_surface file alone: no capture in this step writes it
     file=.mirroir/apps/acme/baselines/checkout.ios.txt present=true
```

A pair still below `min_similarity` after accept is reported rather than
enforced; fix the committed file, and the next ordinary run holds you to it.

### Accept refuses to run in CI

Accepting a baseline is a person saying the new output is correct. A CI job
that could say that would bless its own regressions and report green forever,
so the refusal is structural rather than a documented convention: `accept`
exits non-zero the moment it finds any of `CI`, `CONTINUOUS_INTEGRATION`,
`BUILD_NUMBER`, `GITHUB_ACTIONS`, `GITLAB_CI`, `BITBUCKET_BUILD_NUMBER`,
`BUILDKITE`, `CIRCLECI`, `TRAVIS`, `TEAMCITY_VERSION`, `JENKINS_URL`, or
`TF_BUILD` set.

```
`mirroir-run accept` refuses to run in CI (GITHUB_ACTIONS is set): accepting a
baseline is a human review, and a job that accepts its own drift reports green
forever
```

### The output is a diff

Nothing accept writes is authoritative until a human reads it:

```bash
mirroir-run accept
git diff                      # the reviewed change, as files
git add -p && git commit
```

Every artifact accept touches is a committed file — the baseline store, the
explicit judge baselines, the cross-surface web captures, the lockfile — so
review is `git diff` and the audit trail is the repository's history.

## The lockfile leg

`mirroir.lock` records `checksum: sha256:…` for every resolved archetype, and
`--locked` / `--frozen` recompute it against the tree on disk. A ref string
that did not move and a version pin that did not move over content that *did*
is exactly what a lockfile exists to catch:

```
lockfile is stale relative to mirroir.yaml: ref `./archetypes/checkout` is
locked at checksum sha256:4a1f… but /repo/.mirroir/archetypes/checkout now
hashes to sha256:9c02…
```

In default (local-dev) mode that is a warning naming `accept`; under `--locked`
and `--frozen` it is a refusal. `mirroir-run accept` re-records the lockfile
along with every other baseline, which is how a deliberate edit inside an
archetype tree gets signed off.

## The whole loop, once

```bash
mirroir-run                     # exit 0 — green, and the baseline is recorded
# …someone rewords the confirmation copy…
mirroir-run                     # exit 65 — DRIFT, with a row in .harness/drift-log.md
cat .harness/drift-log.md       # read what moved and by how much
mirroir-run accept              # the reviewed sign-off
git diff                        # the change, as files
git commit -am "chore: accept the reworded order confirmation"
mirroir-run                     # exit 0 again, now holding to the new wording
```

## Related documents

| Topic | Doc |
|---|---|
| Every `SkillStep` variant and where it dispatches | [scenario-grammar.md](scenario-grammar.md) |
| `SAMPLE.md` schema and session boot | [sample-md-format.md](sample-md-format.md) |
| Judge profile registry and the LLM wire format | [judge-profiles.md](judge-profiles.md) |
| The `.mirroir/` consumer dotfile, lockfile, and compose cache | [mirroir-dotfile.md](mirroir-dotfile.md) |
| CI lanes, caching, and exit-code handling | [ci-integration.md](ci-integration.md) |
