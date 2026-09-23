# mirroir-run

Cross-platform replayer for [mirroir](https://mirroir.dev) `SkillStep` YAML
scenarios. Reads scenarios authored against mirroir's step grammar and drives:

- **Web** — compiles steps to Playwright `.spec.ts` and invokes `npx playwright test` against Chromium / Firefox / WebKit.
- **Process** — spawns subprocesses (server lifecycle, CLI tests), captures logs, asserts log shape, kills cleanly.
- **HTTP** — REST probes against MCP, A2A, and other JSON-RPC endpoints.
- **iOS** — hands a `target: { kind: ios }` block to `mirroir-mcp test`, which drives the iPhone through iPhone Mirroring, and reads back the report it writes. macOS hosts only.

Web, process and HTTP run on Linux and macOS without AppKit. An iOS block runs
on a macOS host with mirroir-mcp and iPhone Mirroring; on any other host it is
refused by name, never skipped.

## Status

The locked spec's build sequence (the design gist, §12) has 18 steps. The
runner milestones below cover its spine; iOS delegation and live web↔iOS parity
(steps 17–18, sequential form) run through mirroir-mcp. Still open against the
spec: parallel web/iOS lanes, `wait_for_agui_event`, the LLM
`cross_surface_equivalent` judge, native Anthropic/Ollama judge clients,
per-browser verdicts, and `.compiled.json` drift. `main.rs` dispatches a
multi-mode runner: scenario `--validate` / `--emit playwright` /
`--run-scenario`, `--sample` session replay, `--diff-text` drift, and the
`.mirroir/` consumer pipeline (explicit `--config` or bare-invocation
autodiscovery). Every module carries real implementation — no placeholder code
per `AGENTS.md`.

## Design

Two secret design gists hold the locked specification:

- [Complete planned solution](https://gist.github.com/jfarcand/e4cc69eeddde2ec4988aa20104566c17)
  — every artifact, every browser, every supported sample type, full step grammar,
  drift threshold ownership, build sequence.
- [Brainstorm history](https://gist.github.com/jfarcand/7c30b04801ecfb6ba59c6ca1f62506f7)
  — how we got here (Rust vs. Swift, the Playwright decision, the
  agent + chrome-devtools-mcp canonical chrome recorder).

## Install

```bash
# crates.io
cargo install mirroir-run

# Homebrew
brew install jfarcand/tap/mirroir-run
```

Prebuilt binaries for macOS (Intel + Apple Silicon), Linux (gnu + musl), and
Windows are attached to each [`runner-v*` release](https://github.com/jfarcand/mirroir-mcp/releases).

## Build

To build from source (contributors):

```bash
cd runner
cargo build --release
```

Static-musl Linux binary for CI:

```bash
cargo build --release --target=x86_64-unknown-linux-musl
```

## Usage

Seven modes are wired and verified end-to-end:

```bash
# 0) PRIMARY — `.mirroir/` pipeline. A bare invocation walks `cwd ↑` to the
#    nearest `.mirroir/mirroir.yaml`, resolves archetypes against
#    `~/.mirroir/skills/`, checks the lockfile, composes into `.mirroir/.build/`,
#    then replays each sample. `--config` points at an explicit plan instead.
mirroir-run
mirroir-run --config path/to/.mirroir/mirroir.yaml

# 1) Validate a scenario YAML against the SkillStep grammar.
mirroir-run --validate scenarios/connect-then-broadcast.yaml

# 2) Compile to disk without running: writes target/playwright/<scenario>/
#    with the .spec.ts + playwright.config.ts a run would execute.
mirroir-run --emit playwright scenarios/connect-then-broadcast.yaml
mirroir-run --emit playwright samples/web-fixture --scenarios all

# 3) Accept what a run observed: re-record every baseline, then review `git diff`.
#    Refuses to run in CI — a job must never bless its own drift.
mirroir-run accept
mirroir-run accept --run-scenario scenarios/connect-then-broadcast.yaml

# 4) Run a single scenario end-to-end (process / http / web / judge / drift).
MIRROIR_PLAYWRIGHT_HOME=/path/to/playwright \
  mirroir-run --run-scenario scenarios/connect-then-broadcast.yaml

# 5) Drive a full sample (SAMPLE.md + multiple scenarios; supports boot_once).
MIRROIR_PLAYWRIGHT_HOME=/path/to/playwright \
  mirroir-run --sample samples/mega-sample --scenarios must-pass

# 6) Compute drift between two text files (Jaccard + Levenshtein).
mirroir-run --diff-text baseline.txt current.txt --levenshtein-threshold 0.2
```

The `.mirroir/` pipeline (mode 0) takes these flags: `--config <PATH>` (explicit
plan, overrides cwd-based discovery), `--no-local` (skip `mirroir.local.yaml`),
`--compose-only` (compose `.mirroir/.build/` and exit without replaying),
`--recompose` (delete `.mirroir/.build/` and recompose from scratch),
`--no-compose` (reuse the existing `.build/` tree as-is), `--locked` (CI gate:
error when `mirroir.lock` is missing, stale vs `mirroir.yaml`, or recording a
checksum the archetype tree no longer hashes to), `--frozen`
(`--locked` plus no network fetch), `--report <PATH>` (JSON report artifact),
`--skills <PATH>` (`MIRROIR_SKILLS` checkout, which supplies the global
`drift-defaults.yaml` layer), and `--scenarios <set>`
(defaults to the config's `default_set`, falling back to `must_pass`).

The `samples/mega-sample/` reference walks every primitive in five scenarios:
cross-browser web (chromium + firefox + webkit), `role=` / `text=` locator
engines, HTTP probe, judge + drift against a local Ollama instance, and
cross-surface equivalence. Run it with the command above to verify the full
pipeline on your machine. `samples/web-fixture/` is the lighter companion: a
static-HTML site served by `python3 -m http.server`, with a login flow that
needs no Ollama and no network.

## The three verdicts

Playwright has `passed`, `failed`, `timedOut`, `skipped` and `interrupted`. None
of them can say *every assertion is green, the log is clean, and the semantics
moved*. `mirroir-run` has a third verdict for exactly that, and it gets its own
exit code so a CI lane can decide for itself whether drift blocks a merge.

| Verdict | Exit | Trigger | Artifact |
|---|---|---|---|
| `PASS` | **0** | Every Playwright test passed, every judge score held, every log clean, and no drift metric moved | run summary JSON; `.harness/last-green.json` updated with what this run observed |
| `FAIL` | **1** | A Playwright test failed / timed out / was interrupted, a judge scored below `pass_threshold - tolerance`, a log was dirty, an HTTP status mismatched, a `measure:` blew its `max_seconds` budget, or the runner errored | run summary JSON with the failure verbatim; Playwright trace / screenshot / video |
| `DRIFT` | **65** | Everything above held **and** at least one drift metric moved past its resolved threshold | run summary JSON (`"verdict": "drift"`); a candidate row appended to `.harness/drift-log.md`; the baseline left untouched for review |

Exit code 65 is drawn from the `sysexits.h` band this runner reserves (64-71).
`--diff-text` uses the same code, so `DRIFT` means one thing everywhere.

### Drift metrics

Each is compared against `.harness/last-green.json`, the store the previous
`PASS` run wrote. A scenario with no baseline yet cannot drift: it records what
it saw and passes.

| Metric | Direction | Compares |
|---|---|---|
| `fingerprint_similarity` | floor (`min`) | Jaccard similarity of the judged response's token set |
| `judge_score_swing` | ceiling (`max_delta`) | absolute change in the judge's score |
| `response_levenshtein_pct` | ceiling (`max`) | normalized Levenshtein distance of the judged response |
| `step_latency_pct_increase` | ceiling (`max`) | fractional growth of a `measure:` latency |

### Threshold resolution is fail-closed

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
`unspecified drift threshold for <metric>`. There is no built-in default value,
on purpose: a guessed ceiling silently decides whether a semantic change is
reported as DRIFT or swallowed as a green run.

The `drift-defaults.yaml` search takes the first that exists: the sample
directory, `--skills <dir>` / `$MIRROIR_SKILLS`, the working directory,
`<cwd>/.mirroir/`, then `$HOME/.mirroir/`. This repository ships one at
`runner/drift-defaults.yaml` with the design's starting values; it is a dev
fixture, not part of the published crate, so a consumer declares their own.

```yaml
version: 1
fingerprint_similarity:    { min: 0.85 }
judge_score_swing:         { max_delta: 0.10 }
response_levenshtein_pct:  { max: 0.25 }
step_latency_pct_increase: { max: 0.30 }
```

### Seeing it work

`samples/web-fixture/` ships the pair that makes the verdict concrete:
`summary.html` and `summary-reworded.html` render the same DOM, respond to the
same click, and set the same `data-test` attribute — only the confirmation's
prose differs. Run `scenarios/order-summary.yaml` against one, then the other:
Playwright reports `1 passed` both times and the runner reports `DRIFT` the
second time.

### `mirroir-run accept` — the way out of a DRIFT

A verdict that routes to human review is a trap without a command for *yes,
that is correct now*: the suite's steady state goes amber and someone deletes
it. `accept` runs the same scenarios with the baselines in write mode and turns
a reviewed drift into a `git diff`.

```bash
mirroir-run                     # exit 65 — DRIFT, with a row in .harness/drift-log.md
cat .harness/drift-log.md       # read what moved and by how much
mirroir-run accept              # re-record every baseline from this run
git diff                        # the reviewed change, as files
mirroir-run                     # exit 0 again, now holding to the new output
```

Four artifacts move, and they are the four a DRIFT verdict can point at:
`.harness/last-green.json`, every `judge.drift_baseline_file`, every
`cross_surface.capture.to`, and `.mirroir/mirroir.lock`. `.harness/drift-log.md`
is deleted first — its rows are the queue accept answers. The judge still runs
and its `pass_threshold` is still enforced: accept moves the drift baseline, it
does not bless a response the judge fails.

Every file a `cross_surface:` capture writes — the web block's scrape, the
`ios` block's final screen — is re-recorded from this run. A compared file no
capture writes is committed: accept names it, and leaves it alone.

**Accept refuses to run in CI.** Accepting a baseline is a person saying the
new output is correct; a job that could say it would report green forever. The
refusal is structural: `accept` exits non-zero the moment it finds `CI`,
`GITHUB_ACTIONS`, `GITLAB_CI`, `BUILDKITE`, `CIRCLECI`, `JENKINS_URL`, or any
of the other CI markers set.

`accept` takes the same target selectors an ordinary run does — bare (the
auto-discovered `.mirroir/` plan), `--config <PATH>`, `--sample <DIR>`, or
`--run-scenario <FILE>` — plus `--scenarios`, `--skills`, `--report`, and
`--no-local`.

The complete loop, including how captures travel from the browser through the
Playwright attachment into the post-hooks, is in
[docs/drift-and-accept.md](docs/drift-and-accept.md).

## Documentation

| Topic | Doc |
|---|---|
| The DRIFT verdict, the threshold hierarchy, and `mirroir-run accept` | [docs/drift-and-accept.md](docs/drift-and-accept.md) |
| Scenario grammar (every `SkillStep` variant, dispatch routing) | [docs/scenario-grammar.md](docs/scenario-grammar.md) |
| `SAMPLE.md` schema (`Session`, `Boot`, `Scenarios`, `boot_once`) | [docs/sample-md-format.md](docs/sample-md-format.md) |
| Judge profile registry + Ollama / OpenAI wire format | [docs/judge-profiles.md](docs/judge-profiles.md) |
| Playwright install + `MIRROIR_PLAYWRIGHT_HOME` walkthrough | [docs/playwright-setup.md](docs/playwright-setup.md) |
| CI lanes, caching, exit codes, integration into downstream repos | [docs/ci-integration.md](docs/ci-integration.md) |

## Runner milestones

| # | Milestone | Commit |
|---|-----------|--------|
| 1 | Parser (SkillStep grammar + env substitution + `--validate`) | `9101a2d` |
| 2 | Process target (`spawn/kill/wait_port/assert_log{,_clean}`) | `17ce319` |
| 3 | HTTP target (REST probe with status + body assertions) | `78b7c26` |
| 4 | First runnable CLI smoke scenarios (process + http end-to-end) | `78b7c26` |
| 5 | `SAMPLE.md` + `--sample` mode + `from: SAMPLE.md` resolution | `4ba2aa7` |
| 6 | Compile web steps → Playwright `.spec.ts` + config | `63c3a43` |
| 7 | Invoke `npx playwright test` + ingest JSON reporter | `5bedbac` |
| 8 | Oracle profile registry + drift detection + session boot | `a494206` |
| 9 | Judge `:` post-hook (OpenAI-compatible LLM client) | `6779364` |
| 10 | Cross-browser fallback (chromium + firefox + webkit, real) | verified in `a494206` |
| 11 | Sample expansion — `samples/mega-sample/` reference | `3d2c040` |
| 12 | Session-scoped boot (`session.boot_once: true`) | `a494206` |
| 13 | Cross-surface invariants (`cross_surface:` step primitive) | `2de3692` |

Cross-surface implementation note: the runner provides the equivalence-comparison
primitive (`cross_surface:` step + pairwise Jaccard fingerprint). Surfaces feed
their captured responses to it via filesystem paths. The web side captures via
the compiled spec's `mirroir-captures` attachment, which the runner writes to
the declared path; the iOS side is the `ios` block's final screen, which
`mirroir-mcp test --capture` OCRs and attaches to the same kind of report. Both
land as files the step compares.

## Module layout

```
src/
├── main.rs                # CLI entry; clap arg parsing; dispatches to replay:: / mirroir::
├── accept.rs              # `mirroir-run accept` — re-record every baseline; structural CI refusal
├── error.rs               # RunnerError + Result (thiserror; sub-enums in compile/, mirroir/, oracle/)
├── verdict.rs             # PASS / FAIL / DRIFT + the exit codes they map to
├── replay.rs              # scenario orchestration: hooks and device blocks, in file order
├── replay_plan.rs         # hooks + device blocks (web, ios); one block per surface, contiguous
├── replay_dispatch.rs     # judge / drift / cross_surface / measure post-hook helpers
├── replay_step.rs         # exhaustive SkillStep → runner-side dispatch
├── replay_sample.rs       # `--sample <dir>` session machinery (SAMPLE.md + shared boot)
├── parser/
│   ├── mod.rs             # parser index
│   ├── archetype.rs       # archetype.md manifest (YAML frontmatter + markdown body)
│   ├── env.rs             # ${VAR} / ${VAR:-default} textual substitution
│   ├── substitute.rs      # post-parse ${VAR} substitution on serde_yaml::Value trees
│   ├── local_overrides.rs # mirroir.local.yaml merge (instance wins; arrays replace)
│   ├── lockfile.rs        # mirroir.lock schema + (de)serializer
│   ├── mirroir.rs         # .mirroir/mirroir.yaml plan (samples + archetype refs)
│   ├── mirroir_plan.rs    # archetype reference parsing (pack / ./path / user refs)
│   ├── sample.rs          # SAMPLE.md manifest (fenced-yaml block + Session)
│   ├── scenario.rs        # Scenario top-level (singleton_map_recursive enum form)
│   ├── step.rs            # SkillStep enum — 30 variants (Launch..CrossSurface)
│   ├── step_args.rs       # oracle/verdict step args (judge, drift, http, report, cross_surface)
│   ├── step_process_args.rs # process-target step args (spawn, wait_port, kill, assert_log)
│   └── surface.rs         # web-vs-runner step classification + step-kind labels
├── mirroir/
│   ├── mod.rs             # `.mirroir/` discovery → resolve → compose → run index
│   ├── discover.rs        # walk-up cwd discovery of `.mirroir/mirroir.yaml`
│   ├── resolve.rs         # ArchetypeRef → on-disk directory + manifest (per-kind dispatch)
│   ├── resolve_version.rs # semver-ish version parsing + constraint matching
│   ├── lock.rs            # lockfile modes + --locked/--frozen enforcement
│   ├── lock_freshness.rs  # ref-set + version-pin comparison vs mirroir.yaml
│   ├── lock_checksum.rs   # recompute each locked tree's sha256 vs the recorded checksum
│   ├── lock_generate.rs   # lockfile generation (source/version/checksum + git provenance)
│   ├── compose.rs         # archetype + plan entry → `.mirroir/.build/<sample>/` tree
│   ├── compose_cache.rs   # compose-cache freshness (sha256 + mtime fast-path)
│   ├── compose_synth.rs   # ${VAR} substitution + SAMPLE.md synthesis helpers
│   ├── run.rs             # `run_mirroir` orchestrator (discover+resolve+lock+compose+run_sample)
│   └── run_io.rs          # config + local-override loading + run-summary JSON
├── target/
│   ├── mod.rs             # execution targets index (process + http)
│   ├── process.rs         # tokio::process registry (spawn/kill/SIGTERM/log capture)
│   ├── process_log.rs     # log-capture plumbing (stream pumping, group signalling, regex)
│   ├── process_port.rs    # TCP port-readiness polling for `wait_port:`
│   └── http.rs            # reqwest probe + status/body assertions
├── compile/
│   ├── mod.rs             # compilation targets index (Playwright only today)
│   ├── error.rs           # PlaywrightError (compile / invoke / report-ingest failures)
│   ├── playwright.rs      # scenario → one .spec.ts, incl. the mirroir-captures attachment
│   ├── playwright_config.rs # playwright.config.ts (one project per declared browser)
│   ├── playwright_emit.rs # per-step Playwright emission (key/modifier/swipe/measure)
│   ├── invoke.rs          # spawn `npx playwright test`, keep its output, ingest the report
│   └── report.rs          # JSON-reporter shapes: verdicts, failure text, captures
└── oracle/
    ├── mod.rs             # oracle index (drift + thresholds + baseline + judge)
    ├── error.rs           # OracleError (judge scoring + threshold resolution failures)
    ├── drift.rs           # Fingerprint + Jaccard + Levenshtein verdict
    ├── drift_session.rs   # per-scenario drift accumulator → the DRIFT verdict
    ├── drift_log.rs       # `.harness/drift-log.md` candidate rows
    ├── baseline.rs        # `.harness/last-green.json` — what the previous PASS observed
    ├── thresholds.rs      # fail-closed hierarchy: step → scenario → APP.md → drift-defaults
    ├── judge.rs           # OpenAI-compatible HTTP client + template-hash verification
    └── judge_profiles.rs  # judge profile registry (built-in + overlay, trust-tiered)
```

Single crate; no internal sub-crates until an external consumer appears.

## Relationship to Swift mirroir

This runner does **not** port mirroir's Swift code. Both read the shared
`SkillStep` grammar, and an `ios` block crosses between them:

- `compile::mirroir_block` writes the block in mirroir-mcp's one-step-per-line
  dialect; `target::ios` runs `mirroir-mcp test --report-json … --capture ios`.
- mirroir-mcp's `StepExecutor` drives the phone and writes a Playwright
  JSON-reporter document, which `compile::report` ingests exactly as it does
  Playwright's own.
- The contract is pinned on both sides: Swift's `PlaywrightReportWriterTests`
  checks its writer against `src/target/fixtures/mirroir-mcp-report.json`, the
  file `target::ios`'s tests ingest, and the `Build` workflow runs
  `samples/ios-fixture` through both binaries against FakeMirroring.

The runner owns its own `.mirroir/` consumer pipeline (`runner/src/mirroir/`): a
checked-out repo carries a `.mirroir/mirroir.yaml` plan that lists samples plus
archetype references. The runner discovers it by walking `cwd ↑`, resolves each
archetype against `~/.mirroir/skills/`, verifies the `mirroir.lock` — the locked
ref set, each pin's version constraint, and each recorded `checksum:`
recomputed against the archetype tree on disk, so an edited or tampered pack is
caught rather than replayed — composes the ready-to-replay tree into
`.mirroir/.build/`, and replays it. A stale or drifted lockfile is regenerated
in local-dev mode and refused under `--locked` / `--frozen`; `mirroir-run
accept` re-records it. This
`.mirroir/` dotfile (a consumer repo's checked-in plan) is distinct from `.mirroir-mcp/`,
the Swift MCP server's home directory for element patterns and skills.

## Discipline

This workspace enforces a strict Rust posture documented in the parent
[`AGENTS.md`](../AGENTS.md#rust-workspace-runner). The headlines:

- `unsafe_code = "deny"`. No FFI; any `unsafe` is a hard fail.
- Clippy `all`/`pedantic`/`nursery` at `deny`. `unwrap_used` / `expect_used` /
  `panic` denied in production code.
- `anyhow!()` macro forbidden — structured `RunnerError` everywhere; convert
  external errors via `#[from]` or `.map_err(|source| RunnerError::Variant { ... })`.
- `anyhow::Context` disallowed via `clippy.toml` `disallowed-methods`.
- Test functions return `Result<()>` and propagate via `?` — no `.unwrap()` /
  `.expect()` / `panic!()` even in test code.
- Every `.rs` file starts with two `// ABOUTME:` header lines. Max 500 lines
  per file.

`scripts/ci/pre-push-validate.sh` enforces these mechanically: fmt, the
limitation-register gates (`.registre/limitation-gates.sh` at the repo root —
deferral prose ban, 500-line cap, inline clippy allow-list), clippy, tests.

## License

Apache-2.0 — same as the parent `iphone-mirroir-mcp` project.
