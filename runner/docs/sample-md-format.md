# `SAMPLE.md` format

`SAMPLE.md` is the per-sample contract `mirroir-run --sample <dir>` loads.
Markdown body is for human readers; the runner extracts the **first
fenced ` ```yaml ` (or ` ```yml `) block** and deserializes it.

Source of truth: `runner/src/parser/sample.rs`. Reference example:
`runner/samples/mega-sample/SAMPLE.md`.

## Minimal manifest

```yaml
version: 1
session:
  boot:
    command: "java -jar target/server.jar"
  scenarios:
    must_pass:
      - scenarios/smoke.yaml
```

## Full manifest with every field

```yaml
version: 1                                   # required; major-version-gated
name: "spring-boot-chat"                     # optional human label
description: |                               # optional multi-line prose
  Boot the chat sample, run smoke scenarios.

session:
  boot:
    command: "java -jar target/server.jar"   # required
    cwd: "samples/chat"                      # optional; resolved relative to SAMPLE.md's parent
    env:                                     # optional env overrides for the boot process
      SPRING_PROFILES_ACTIVE: ci
      LOG_LEVEL: INFO
    timeout_s: 60                            # optional ceiling on boot runtime

  boot_once: true                            # default false
                                             # when true: spawn ONCE before scenarios, kill after
                                             # scenarios using `spawn: { from: SAMPLE.md, id: session }`
                                             # become no-ops (the subprocess is already running)

  boot_ready_port: 8081                      # consulted only when boot_once=true
                                             # waits for this port to accept connections before scenarios start

  boot_ready_timeout_s: 60                   # default 60; only when boot_ready_port is set

  scenarios:
    must_pass:                               # FAIL on any of these → sample run exits non-zero
      - scenarios/connect-then-broadcast.yaml
      - scenarios/ws-reconnect.yaml
    nice_to_pass:                            # informational; FAIL doesn't block
      - scenarios/slow-network-buffer.yaml
```

## Versioning

- `version: 1` is the only currently-accepted major. Mismatch returns
  `RunnerError::UnsupportedVersion` at load time.
- New optional fields land with `#[serde(default)]` so older `SAMPLE.md`
  files keep parsing.
- Breaking changes bump to `version: 2` and the runner gates accordingly.

## `boot_once` semantics

When `boot_once: true`:

1. `mirroir-run --sample` creates a top-level `ProcessRegistry`.
2. Spawns the boot command with id `"session"` into that registry.
3. If `boot_ready_port` is set, blocks on that port up to `boot_ready_timeout_s`.
4. Runs each scenario in `scenarios.<set>` against the shared registry.
   Scenarios that declare `spawn: { from: SAMPLE.md, id: session }` see
   the id is already live and the spawn becomes an idempotent no-op
   (logged as `ensure_spawned: id already live; skipping re-spawn`).
5. Any scenario-level `kill:` step is a no-op when `boot_once` is on (the
   no-op is gated on session-shared mode, not on the killed id) — the shared
   subprocess survives across scenarios.
6. After the last scenario, the runner tears down the shared subprocess
   (SIGTERM → grace → SIGKILL).

When `boot_once: false` (default): each scenario gets a fresh
`ProcessRegistry`, spawns/kills are scoped to that scenario only.

## Scenario path resolution

All paths in `scenarios.*` are **relative to the SAMPLE.md's parent directory**.
For example `scenarios/foo.yaml` in `samples/spring-boot-chat/SAMPLE.md`
resolves to `samples/spring-boot-chat/scenarios/foo.yaml`.

## `${MIRROIR_SAMPLE_DIR}` substitution

In `--sample` mode, scenarios can reference paths relative to the sample
directory via `${MIRROIR_SAMPLE_DIR}`. The runner injects this into the
env-substitution pass without mutating process env (so other tools running
in parallel don't observe the change). Example:

```yaml
- judge:
    drift_baseline_file: "${MIRROIR_SAMPLE_DIR}/baselines/judge.txt"
```

## `baselines/*.ios.txt` must be compared by a declared scenario

An iOS baseline is captured by mirroir-mcp's `generate_skill` against a
connected iPhone; `mirroir-run` drives no executor for that surface and can
only read the file. The single thing that gives one an effect is a
`cross_surface:` step naming it in `response_files`, so a `.ios.txt` no
scenario names is read by nothing and the sample reports green with the parity
gate it was captured for absent.

`--sample` refuses such a sample before the session boots, naming the file. The
scenarios that count are the ones this `SAMPLE.md` declares, in either tier: a
capture no declared scenario compares is an orphan, and no invocation can make
it otherwise. The remedy is to name it from a scenario, or to delete a capture
nothing checks.

A baseline a declared scenario *does* name, on a run whose `--scenarios` set
leaves that scenario out, is a different thing: the sample checks the gate and
this run does not. That is the tier the invocation chose — the run logs a
warning naming the baseline and proceeds, so `--scenarios nice-to-pass` stays
runnable against a sample whose parity scenario is `must_pass`.

The name is the contract: `<flow>.ios.txt`, flat under `baselines/`. A capture
spelled any other way, or filed in a subdirectory, is not accounted for.

## CLI control

```bash
# Run must_pass set (default)
mirroir-run --sample samples/mega-sample

# Run nice_to_pass set
mirroir-run --sample samples/mega-sample --scenarios nice-to-pass

# Run both, in order: must_pass first then nice_to_pass
mirroir-run --sample samples/mega-sample --scenarios all
```

## Reference: the `mega-sample` walk-through

`runner/samples/mega-sample/` exercises every primitive in five scenarios:

| Scenario | Drives |
|---|---|
| `scenarios/web-cross-browser.yaml` | Playwright across chromium + firefox + webkit |
| `scenarios/web-locator-engines.yaml` | `role=` / `text=` locator-engine pass-through (chromium) |
| `scenarios/http-probe.yaml` | reqwest GET 200 + body match |
| `scenarios/judge-and-drift.yaml` | Ollama judge + drift vs. baseline |
| `scenarios/cross-surface.yaml` | Pairwise fingerprint equivalence (web ↔ iOS captures) |

`runner/samples/web-fixture/` is the hermetic companion: static HTML served by
`python3 -m http.server`, driven through Playwright with no Ollama and no
network. Its `scenarios/login.yaml` is the reference contiguous web block —
process lifecycle and HTTP probes in Rust, one adjacent run of web steps
between them.

Run it locally:

```bash
cd runner
MIRROIR_PLAYWRIGHT_HOME=/path/to/playwright \
  cargo run --release --bin mirroir-run -- --sample samples/mega-sample
```

Requires: Python 3 (for the http.server boot), Node + `@playwright/test` +
chromium under `MIRROIR_PLAYWRIGHT_HOME`, and a running `ollama serve` with
`qwen2.5:0.5b` pulled. See [playwright-setup.md](playwright-setup.md) and
[judge-profiles.md](judge-profiles.md) for the one-time installs.
