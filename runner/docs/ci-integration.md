# CI integration

How downstream consumers (e.g., Atmosphere samples, mirroir-skills test
suites) call `mirroir-run` from their own CI. The reference is
[`.github/workflows/runner.yml`](../../.github/workflows/runner.yml) in
this repository.

## Job shape

`runner.yml` defines seven jobs. Five are test lanes; two are guard jobs
(`runner-deny` runs `cargo deny check`, `publish-rehearsal` runs
`cargo publish --dry-run --locked`).

```
push / PR                                                nightly Sun 03:00 UTC + manual
   │                                                                 │
   ▼                                                                 ▼
┌─────────────┐ ┌─────────────┐ ┌──────────────────┐ ┌─────────────┐ ┌──────────────────────┐
│ runner-fast │ │runner-smoke │ │ runner-full-loop │ │  runner-e2e │ │ runner-e2e-allbrowsers│
│  ~3 min     │→│  ~30 s      │→│  ~2 min          │→│  ~5 min     │ │  ~12 min              │
│  fmt clippy │ │ process http│ │ the 13 phases    │ │ Playwright  │ │ chrome+firefox+webkit │
│  test diff  │ │ cross_surf  │ │ boot→…→lockfile  │ │  + Ollama   │ │  + Ollama             │
└─────────────┘ └─────────────┘ └──────────────────┘ └─────────────┘ └──────────────────────┘
   linux+macos     linux+macos       linux+macos        linux+macos       linux + macos

┌─────────────┐ ┌──────────────────────┐
│ runner-deny │ │  publish-rehearsal   │
│ cargo deny  │ │ cargo publish        │
│   check     │ │  --dry-run --locked  │
└─────────────┘ └──────────────────────┘
     linux              linux
```

`runner-full-loop` and `runner-smoke` both branch off `runner-fast`;
`runner-full-loop` runs `runner/tests/e2e_full_loop.rs`, the acceptance test
that drives the whole loop against a real chromium in one run — boot, one
Playwright invocation, the capture channel, the judge, the runner-side hooks,
PASS, an idempotent rerun, DRIFT, `accept`, green again, a real break, the
artifacts it leaves, and the lockfile gate. The suite reports `NOT RUN` and
stays green on a host that provisioned no browser, so the lane also greps its
output for `FULL LOOP: 13/13 phases observed` — a vacuous pass fails the lane.

Lanes downstream of `runner-fast` use the `needs:` keyword so they only
spin up runners after the fast lane is green — saves runner-minutes on
PRs that have a basic regression.

## Path filters

The workflow only triggers when files under `runner/**` or the workflow
file itself change. This keeps Swift-only commits from spending runner
time on Rust CI and vice versa.

## Caching strategy

| Cache | Key | What it stores |
|---|---|---|
| Cargo registry + git + `runner/target` | `Swatinem/rust-cache@v2`, shared-key per lane | crates.io index, downloaded crates, incremental compilation artifacts |
| Playwright browsers | `playwright-${{ runner.os }}-<cache-key>`, set by `.github/actions/setup-playwright` | `~/.cache/ms-playwright` (Linux), `~/Library/Caches/ms-playwright` (macOS) |
| Ollama models | `ollama-${{ runner.os }}-qwen2.5:0.5b-v1` | `~/.ollama/models` (~400 MB for the qwen2.5:0.5b judge model) |

Bump the trailing `-v1` suffix to force a cache rotation when the
underlying tool's binary digest changes (e.g., Playwright minor-version
bump).

## Why Ollama and not OpenAI

`mirroir-run`'s `byte-stable` judge profile targets a local Ollama daemon.
CI installs Ollama on every fresh runner and uses it for judge scoring. No
secrets, no per-run cost, byte-stable across reruns at `temperature=0`.

The `fast-ci` profile (OpenAI `gpt-4o-mini`) is documented and supported
for local users who prefer hosted scoring, but never invoked in CI to keep
the workflow free of remote-LLM dependencies.

### Profile trust boundary

Built-in profiles and the user's home config
(`~/.mirroir/oracles/profiles.yaml`) are trusted: they may set a profile's
`base_url` / `api_key_env` / `model` / `timeout_s` and define new profiles.
Repo-local config (`<repo>/oracles/profiles.yaml` and
`<repo>/.mirroir/oracles/profiles.yaml`) is untrusted: it may only tune
`model` / `timeout_s` of an existing profile. A repo-local `base_url` /
`api_key_env` change or a brand-new profile is ignored with a warning, so a
checked-out repository cannot redirect judge prompts and API keys to an
attacker-controlled host.

Independently, the judge's `user_prompt_template_hash` is verified on every
run: a scenario that pins a stale hash hard-fails with
`RunnerError::JudgeTemplateMismatch`, so a changed oracle template can never
silently invalidate a scenario's reproducibility guarantee.

## Consuming the runner from another repo's CI

Every `runner-v*` tag publishes prebuilt binaries for
`x86_64-unknown-linux-gnu`, `x86_64-unknown-linux-musl`, `x86_64-apple-darwin`,
`aarch64-apple-darwin`, and `x86_64-pc-windows-msvc`, plus the crate on
crates.io and a formula in the `jfarcand/homebrew-tap` tap. Pick whichever fits
the lane; no lane needs to build from source.

```yaml
- name: Install mirroir-run (prebuilt, static musl)
  env:
    MIRROIR_RUN_VERSION: 0.2.0
  run: |
    base="https://github.com/jfarcand/mirroir-mcp/releases/download/runner-v${MIRROIR_RUN_VERSION}"
    curl -fsSL "${base}/mirroir-run-v${MIRROIR_RUN_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
      | tar -xz -C /tmp
    sudo install "/tmp/mirroir-run-v${MIRROIR_RUN_VERSION}-x86_64-unknown-linux-musl/mirroir-run" \
      /usr/local/bin/mirroir-run

- name: Install Playwright + Ollama (see runner-e2e in the upstream workflow)
  run: |
    # ... same install + cache pattern as runner.yml ...

- name: Drive your sample
  run: mirroir-run --sample path/to/your/sample
```

The other two install paths:

```bash
cargo install mirroir-run --locked          # crates.io
brew install jfarcand/tap/mirroir-run       # Homebrew (macOS arm64/x86_64, Linux x86_64)
```

Each release archive ships a `.sha256` sidecar next to it; verify it when the
lane's threat model calls for it.

## Exit codes

| Exit | Verdict | Meaning |
|---|---|---|
| 0 | `PASS` | All scenarios in the chosen set passed and nothing drifted |
| 1 | `FAIL` | One or more scenarios failed; check stderr for the typed `RunnerError` |
| 65 | `DRIFT` | Every structural assertion held and at least one drift metric moved past its threshold |
| 64, 66-71 | — | Reserved (per `sysexits.h` convention; not currently used by the runner) |

The runner never returns successfully with a partial pass — `must_pass`
scenarios must all be green. It does return a *third* code, and the lane
decides what that means:

```yaml
- name: Drive the sample
  run: |
    set +e
    mirroir-run --sample path/to/sample
    code=$?
    set -e
    case "$code" in
      0)  echo "PASS" ;;
      # A drifted run held structurally and moved semantically. Uploading the
      # candidate rows and continuing is the usual choice; `exit 1` here makes
      # drift block the merge instead.
      65) echo "DRIFT — review .harness/drift-log.md"; cat .harness/drift-log.md ;;
      *)  exit "$code" ;;
    esac

- uses: actions/upload-artifact@v4
  if: always()
  with:
    name: drift-candidates
    path: .harness/drift-log.md
    if-no-files-found: ignore
```

`--diff-text` returns 65 on drift too, so the code means one thing everywhere.

### Never `accept` in CI

The way out of a DRIFT is `mirroir-run accept`, which re-records every baseline
from what the run observed. That is a person saying the new output is correct.
A CI job that ran it would bless its own regressions and report green forever,
so the refusal is structural rather than a convention this document asks you to
follow: `accept` exits non-zero the moment it finds `CI`, `GITHUB_ACTIONS`,
`GITLAB_CI`, `BUILDKITE`, `CIRCLECI`, `JENKINS_URL`, or any of the other CI
markers set. Adding it to a workflow turns the lane red, not green.

The intended flow is: CI reports 65 and uploads `.harness/drift-log.md`; a
person reads the rows, runs `mirroir-run accept` on their machine, reviews
`git diff`, and commits the moved baselines. See
[drift-and-accept.md](drift-and-accept.md).

### Drift thresholds in CI

Drift comparison is fail-closed: a metric no layer of the hierarchy declares
stops the run with `unspecified drift threshold for <metric>` (exit 1). The
global layer is required outright: every `--run-scenario` / `--sample` / `accept`
run loads it before the first step, and a run that finds no
`drift-defaults.yaml` is refused (`no drift-defaults.yaml found`, exit 1) —
`--validate` and `--diff-text` load no thresholds and need nothing. The file
must be reachable from the invocation — in the sample directory, at
`--skills <dir>` / `$MIRROIR_SKILLS`, in the working directory, under
`<cwd>/.mirroir/`, or under `$HOME/.mirroir/`.

Its one copy lives at the root of the
[mirroir-skills](https://github.com/jfarcand/mirroir-skills) repo. A lane that
runs scenarios checks it out and points `MIRROIR_SKILLS` at it:

```yaml
- name: Clone skills repo (global drift-defaults.yaml)
  run: git clone https://github.com/jfarcand/mirroir-skills.git ../mirroir-skills
- name: Run scenarios
  env:
    MIRROIR_SKILLS: ${{ github.workspace }}/../mirroir-skills
  run: mirroir-run --sample path/to/sample
```

A consumer whose `.mirroir/` tree was emitted by `generate_skill` already holds
a seeded copy at `.mirroir/drift-defaults.yaml`, found when the run starts from
the repo root. See the README's "The three verdicts" section for the metrics
and their starting values.

The baseline drift is measured against lives at `.harness/last-green.json`,
relative to the invocation directory. A fresh CI runner has none, so the first
run of a scenario records one and passes; cache or commit that file only if the
lane genuinely wants cross-run drift detection.

### Report artifact

The `.mirroir/` pipeline writes a JSON run summary to the path given by
`--report` (default `mirroir-run-report.json`). CI can upload it as a
build artifact for post-mortem. The shape is `RunSummary`:

```json
{
  "version": 2,
  "config_path": "/abs/path/.mirroir/mirroir.yaml",
  "generated_at": "2026-06-19T03:00:00Z",
  "samples": [ /* per-sample SampleVerdict entries, in plan order */ ],
  "totals": { "samples": 3, "passed": 2, "failed": 0, "drifted": 1, "skipped": 0 }
}
```

Schema `2` added the third verdict: `samples[].verdict` is one of `"pass"`,
`"fail"`, `"drift"`, `"skipped"`, `"composed"`, and `totals` carries a
`drifted` count. The four strings a version-1 consumer already grepped for are
unchanged.

## Verbose logging in CI

Set `RUST_LOG=debug` to see the dispatcher's per-step trace:

```yaml
- run: RUST_LOG=debug ./target/release/mirroir-run --sample samples/foo
```

Output is line-oriented `tracing-subscriber` formatted; pipe through
`grep` / `awk` to slice. The `runner-e2e` lane tails the Ollama daemon
log on failure for post-mortem.

## Matrix expansion

The current workflow runs on `[ubuntu-latest, macos-latest]`. To add
Windows (not currently supported — `nix` SIGTERM handling is unix-only):

1. Implement the non-unix `send_group_sigterm` / `send_group_sigkill`
   stubs in `runner/src/target/process_log.rs` (currently no-ops under
   `#[cfg(not(unix))]`; `process.rs` only calls them).
2. Add `windows-latest` to the matrix.
3. Adjust Ollama install (Windows uses the `.exe` installer).

Tracking the Windows port: open a GitHub issue with the `os:windows`
label when you need it.

## Sample expansion: driving many samples

This repository ships a single end-to-end fixture,
[`runner/samples/mega-sample`](../samples/mega-sample), exercised by the
`runner-e2e` lane. A downstream consumer drops a `SAMPLE.md` next to each
source it wants `mirroir-run` coverage for, then runs each from its own
CI:

```yaml
- run: mirroir-run --sample path/to/sample-a --scenarios must-pass
- run: mirroir-run --sample path/to/sample-b --scenarios must-pass
```

…or a single matrix job iterating over sample directories. See
[sample-md-format.md](sample-md-format.md) for the `SAMPLE.md` schema.

Consumer-specific sample integration lives in the consumer repo's own CI;
this runner's job is to be the binary they invoke, with stable exit codes
and structured logs.
