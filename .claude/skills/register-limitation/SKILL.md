---
name: register-limitation
description: Register a known gap in the limitation register — file the issue in the private tracker, write the LIMITATION(registre#n) marker, or ledger a dark-launched feature. Use when the register gates fail, or when you are about to document why something is incomplete.
user-invocable: true
---

# Register a Limitation

## When this fires

Any of these, without exception:

- The register gates failed — "unregistered deferral/confession prose", "malformed LIMITATION
  marker", a file over the 500-line cap, or an inline clippy allow outside the declared list.
- You are about to write a comment explaining why something is incomplete, restricted, or deferred.
- You are shipping a feature **disarmed** (flag off, shadow mode, log-only phase).
- You found a gap while reading code and are not fixing it in this change.

The gates are the Apache-2.0 [llm-registre](https://github.com/dravr-ai/llm-registre) tool,
vendored as the `.registre` submodule and run by Tier 1 of
`runner/scripts/ci/pre-push-validate.sh` and by CI (`limitation-register.yml`).

## Step 0 — try to not need this

The register exists so honest gaps become tracked obligations, **not** so gaps become easy to
ship. If you can implement the real thing now, do that instead. Registering is the fallback, and
it costs a permanent entry someone has to close later. (A file over the cap or a stray inline
allow is never registered — extract the helper or fix the lint.)

## Where issues go

**Read `registre.toml` at the repo root — its `tracker` key names this repo's register.** Never
assume; registers are per project. For mirroir that is `jfarcand/mirroir-carnet`.

```bash
grep tracker registre.toml
```

| | |
|---|---|
| Tracker | whatever `registre.toml` says |
| Labels | `limitation` + this repo's name (`iphone-mirroir-mcp`) |
| Title | `[mirroir-mcp] <short statement of the gap>` — always project-prefixed (`registre.toml` → `project`) |

**Never file on the code repo itself.** It is PUBLIC, and a limitation issue states precisely
where a capability or defence is incomplete — a roadmap when the code is open. Issue bodies may
hold reasoning and residual risk; the code comment stays thin.

## Step 1 — file the issue

File it through the `carnet` skill's script — the one path into the register. It reads the
tracker from `registre.toml`, refuses a public tracker, prefixes the title `[<project>] `, and
adds the project label. Pass `--label limitation` because a marker will point at this issue.

```bash
.claude/skills/carnet/carnet.sh create \
  --label limitation \
  --title "Short statement of the gap" \
  --body "Where it is (file + symbol). What is incomplete. What the correct fix looks like."
# → https://github.com/jfarcand/mirroir-carnet/issues/42
#   marker: LIMITATION(registre#42): <name the limited item on this line>
```

Add `--claim` when you are about to keep working the gap in this session, so a peer sees it
held. The ledger line `create` writes is also how `bilan` credits the issue as a registered
limitation rather than work this session owes.

## Step 2 — write the marker

On the comment line that names the limited item:

```rust
// LIMITATION(registre#1): device-only step kinds (launch, home, shake,
// reset_app, set_network, measure, condition) have no replay dispatch arm.
```

Rules that make a marker valid rather than decorative:

- The literal is `registre#<number>` — the bare word, never the tracker repo name. The tracker is
  configuration (`registre.toml`); the marker never changes when it moves.
- **Name the limited item on the marker line** (the symbol, variant, or tool). A marker that says
  only "this is incomplete" is unsearchable.
- The marker exempts **its own line** from the prose ban, not the file. A second unmarked deferral
  sentence on the next line still fails.
- **Put it in source the gates scan.** Test, bench, example and generated trees are outside the
  scan (`.registre/limitation-gates.sh --list-files` prints what is in), so a marker there is
  validated by nothing and never credits the issue as registered. A gap in test *coverage*
  belongs to the production item that goes uncovered: mark that item, where the next person to
  change it reads it.

## Step 3 — if the feature ships disarmed, ledger it too

Add to `feature-phases.yaml` (fixed shape — the review workflow parses it with `awk`):

```yaml
  - name: kebab-case-feature-name
    surface: Sources/mirroir-mcp/TheFlag.swift
    current: what ships today, i.e. the disarmed state
    advance_when: the criterion that arms the next phase
    review_by: 2026-09-30
```

The weekly "Monitor: Feature Phase Review" workflow opens a `feature-phase` issue in the tracker
once `review_by` passes, so phase 1 cannot silently become forever. Keep values free of `": "`
and `" #"`.

## Step 4 — verify

```bash
./.registre/limitation-gates.sh Sources runner/src npm scripts website/src
```

Expect all five gates green. Tier 1 of `runner/scripts/ci/pre-push-validate.sh` runs the same
command before every push.

## Closing an entry

Fix the gap, **delete the marker in the same change**, close the issue. A stale marker still
exempts prose from the gates, so exhausted markers are debt of their own.

## What the register does not cover

These gates are per-change: they stop new debt at authoring time and cannot reach the standing
stock of defects that live between diffs — a handler nothing reaches, an override nothing reads,
two components each locally correct and jointly wrong. Those come out of periodic adversarial
cold-reads and get filed here like anything else. A green gate means no new unregistered debt, not
a clean codebase.
