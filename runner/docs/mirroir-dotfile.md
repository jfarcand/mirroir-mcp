# `.mirroir/` Dotfile — User Reference

> Canonical architecture reference: [gist.github.com/jfarcand/a0ef5d91043851e70ceeb728553514c4](https://gist.github.com/jfarcand/a0ef5d91043851e70ceeb728553514c4)

This page is the practical guide for authoring + running `.mirroir/` in a
consumer repository. It covers the schema, lockfile workflow, archetype
references, local overrides, and CLI flags.

## TL;DR

```bash
# In your project root, create the dotfile tree:
mkdir -p .mirroir
cat > .mirroir/mirroir.yaml <<'YAML'
version: 1
plan:
  must_pass:
    - name: my-app
      archetypes: [mirroir-skills/atmosphere/ai-console@v1]
      flows: [chat-stream]
      vars: { PORT: "8080" }
      boot:
        command: "./mvnw spring-boot:run"
        boot_ready_port: 8080
YAML

# Install the archetype pack once per machine:
git clone --branch v1.0.0 https://github.com/jfarcand/mirroir-skills \
          ~/.mirroir/skills/mirroir-skills/1.0.0

# Replay (anywhere inside your project root):
mirroir-run
```

## Directory layout

```
<your-repo>/.mirroir/
├── mirroir.yaml          # plan + per-sample config (committed)
├── mirroir.local.yaml    # personal overrides (gitignored)
├── mirroir.lock          # exact archetype resolutions (committed)
├── apps/                 # local samples that don't extend an archetype
│   └── <name>/
│       ├── APP.md
│       ├── SKILL.md
│       ├── SAMPLE.md
│       └── scenarios/<flow>.yaml
├── archetypes/           # project-local archetypes (rare; `./` refs point here)
└── .build/               # composed output (gitignored, regenerated)

~/.mirroir/skills/<pack>/<version>/   # installed archetype packs
```

## Authoring `mirroir.yaml`

Two flavors of plan entry — archetype-extending and local.

### Archetype-extending entry

```yaml
- name: spring-boot-ai-chat
  archetypes: [mirroir-skills/atmosphere/ai-console@v1]
  flows: [chat-stream]
  vars:
    PORT: "8080"
  boot:
    command: "./mvnw -q spring-boot:run -pl samples/spring-boot-ai-chat"
    cwd: "${ATMOSPHERE_HOME:-.}"
    env:
      LLM_MODE: fake
      ATMOSPHERE_AUTH_ENABLED: "false"
    boot_ready_port: 8080
    boot_ready_timeout_s: 120
```

- `archetypes:` is a list (v1: exactly one entry).
- `flows:` picks which of the archetype's `provides.flows` to run.
- `vars:` fills `${VAR}` placeholders in the archetype's source files.
- `boot:` is verbatim per-instance wiring; supports `${VAR}` substitution.

### Local entry

```yaml
- name: legacy-app
  local: apps/legacy-app
  boot:
    command: "./mvnw jetty:run"
    boot_ready_port: 8080
```

Local entries reference a self-contained `.mirroir/apps/<dir>/` tree
with its own APP.md / SKILL.md / SAMPLE.md / scenarios. No archetype,
no compose-time substitution — the runner consumes the tree directly.

### Tiers

- `plan.must_pass[]` — failure blocks the suite (exit non-zero).
- `plan.nice_to_pass[]` — informational; failure does not block.

## Archetype references

Three reference forms, each resolved against a different location:

| Form | Resolves to |
|------|-------------|
| `<pack>/<name>@<version>` | `~/.mirroir/skills/<pack>/<resolved-version>/archetypes/<name>/` |
| `./<path>` | `<repo>/.mirroir/<path>/` |
| `user/<name>@<version>` | `~/.mirroir/archetypes/<name>/<resolved-version>/` |

**Bare `<name>` references are invalid** — always use one of the three
forms above to disambiguate.

Version constraints:
- `@1.2.3` — exact pin
- `@v1` or `@1` — floating major (highest installed 1.x.x)
- `@v1.0` or `@1.0` — floating minor
- `@latest` or omitted — floating any (CI should pin via lockfile)

## Lockfile

`mirroir.lock` records the exact resolution of each archetype ref at
lock time. It is **committed**.

```yaml
version: 1
generated_at: 2026-05-16T18:22:14Z
generated_by: mirroir-run 0.1.2
archetypes:
- ref: mirroir-skills/atmosphere/ai-console@v1
  resolved:
    kind: pack
    pack: mirroir-skills
    name: atmosphere/ai-console
    version: 1.0.0
    source:
      url: https://github.com/jfarcand/mirroir-skills
      tag: v1.0.0
      commit: 0f67289ab...
    checksum: sha256:c3bac34c7bb4...
```

### What is verified

Two questions, both asked on every run:

1. **Does the lockfile still describe `mirroir.yaml`?** The locked ref set must
   match the plan's, and each recorded `resolved.version` must still satisfy its
   ref's `@<version>` constraint.
2. **Does each locked tree still hash to its recorded `checksum:`?** The
   archetype directory is walked and re-hashed, and the result compared to what
   the lockfile recorded.

The second question is the one a ref-set diff cannot answer. A locally edited
archetype, a pack rewritten in place under the same tag, a tampered install —
the ref string and the version pin are all untouched, and only the checksum
moves:

```
lockfile is stale relative to mirroir.yaml: ref `./archetypes/checkout` is
locked at checksum sha256:4a1f… but /repo/.mirroir/archetypes/checkout now
hashes to sha256:9c02…
```

### Modes

| Mode | When | Behavior on a stale or drifted lockfile |
|------|------|----------------------------|
| Default | `mirroir-run` (no `--locked` / `--frozen`) | Regenerate a stale lockfile; warn on a checksum that moved, naming `mirroir-run accept` |
| `--locked` | CI | Exit non-zero with `MirroirLockfileStale` |
| `--frozen` | Hermetic offline CI | As `--locked` plus forbid network fetch |

### Re-recording the lockfile

`mirroir-run accept` re-resolves every archetype the plan references and
rewrites `mirroir.lock` with the versions and tree checksums on disk right now.
That is how a deliberate edit inside a project-local archetype gets signed off
for `--locked` and `--frozen`:

```bash
# …edit .mirroir/archetypes/<name>/…
mirroir-run --frozen              # refuses: the tree no longer hashes to the lock
mirroir-run accept                # re-records the lockfile (and every baseline)
git diff .mirroir/mirroir.lock    # inspect the change
git add .mirroir/mirroir.lock
git commit -m "chore(mirroir): bump archetype lockfile"
mirroir-run --frozen              # green again
```

Default mode also regenerates a lockfile that is stale by ref set, so a plain
`mirroir-run` after adding an archetype reference fixes it and warns once.

## Local overrides (`mirroir.local.yaml`)

A gitignored sibling to `mirroir.yaml`. Merges per-entry by `name`.

```yaml
version: 1
plan:
  must_pass:
    - name: spring-boot-ai-chat
      vars: { PORT: "18080" }       # personal port reassignment
      boot:
        env: { LLM_MODE: real }     # merged into base boot.env per key
    - name: heavy-sample
      skip: true                    # exclude from local runs
```

Merge semantics:

- **Scalars** (strings, numbers, bools) → replace.
- **Maps** (`vars`, `boot.env`) → per-key merge; instance override wins per key.
- **Arrays** (`flows`, `archetypes`) → **replace**, not append.
- `skip: true` excludes from the run. It is reported as `skipped`, and a run in
  which every selected entry is skipped exits 1: replaying nothing is not a pass.

CI disables overrides via `mirroir-run --no-local`.

## `${VAR}` substitution

Substitution is **post-parse**, on **string-leaves only**. Values with
embedded `:`, `"`, newlines, or `${...}` are opaque to the YAML parser
— no Helm-class quoting footguns.

Resolution chain (highest priority first):
1. Plan entry `vars`
2. Plan entry `boot.env`
3. Suite-level `env`
4. Archetype `requires.vars[].default`
5. Process environment
6. Inline `${VAR:-fallback}`
7. Empty string

Keys are **not** substituted — `${KEY}: value` stays a literal `${KEY}`.

## CLI flags

`.mirroir/` pipeline flags:

```
mirroir-run                              # auto-discover .mirroir/, replay
mirroir-run --config <PATH>              # explicit mirroir.yaml path
mirroir-run --no-local                   # skip mirroir.local.yaml
mirroir-run --scenarios must-pass        # tier selector (config default_set when omitted)
mirroir-run --scenarios all              # include nice-to-pass
mirroir-run --compose-only               # compose without replaying
mirroir-run --recompose                  # delete .build/, recompose, replay
mirroir-run --no-compose                 # use existing .build/, no recompose
mirroir-run --locked                     # CI gate: stale lockfile is an error
mirroir-run --frozen                     # --locked + no network fetch
mirroir-run --report <PATH>              # JSON summary path (default mirroir-run-report.json)
mirroir-run --skills <PATH>              # mirroir-skills checkout (env MIRROIR_SKILLS)
mirroir-run --levenshtein-threshold <FLOAT>  # drift threshold for --diff-text (default 0.2)
```

Baseline re-recording:

```
mirroir-run accept                       # auto-discovered plan; re-record every baseline
mirroir-run accept --config <PATH>       # explicit mirroir.yaml
mirroir-run accept --sample <DIR>        # one sample's scenario set
mirroir-run accept --run-scenario <FILE> # one scenario
```

`accept` also takes `--scenarios`, `--skills`, `--report`, and `--no-local`. It
writes `.harness/last-green.json`, every `judge.drift_baseline_file`, every
`cross_surface.capture.to`, and `.mirroir/mirroir.lock`, deletes
`.harness/drift-log.md`, and **refuses to run when a CI environment variable is
set** — accepting a baseline is a human review, and a job that accepts its own
drift reports green forever. See
[drift-and-accept.md](drift-and-accept.md) for the whole loop.

The pre-`.mirroir/` modes still work (`--sample`, `--validate`,
`--run-scenario`, `--emit playwright`, `--diff-text`).

## Summary JSON

After every run, mirroir-run writes a summary to `--report`:

```json
{
  "version": 1,
  "config_path": "/path/.mirroir/mirroir.yaml",
  "generated_at": "2026-05-17T...",
  "samples": [
    { "name": "spring-boot-ai-chat", "verdict": "pass" },
    { "name": "spring-boot-broken", "verdict": "fail", "error": "..." }
  ],
  "totals": { "samples": 21, "passed": 21, "failed": 0, "skipped": 0 }
}
```

`verdict` is `pass` / `fail` / `skipped` / `composed` (the last only
appears under `--compose-only`).

## Compose pipeline + `.build/` cache

When the runner sees an archetype-extending entry, it composes the
archetype + instance into `<repo>/.mirroir/.build/<entry.name>/`:

```
.mirroir/.build/spring-boot-ai-chat/
├── SAMPLE.md                # synthesized from plan entry boot
├── APP.md                   # archetype APP.md with ${VAR} substituted
├── SKILL.md                 # archetype SKILL.md substituted
├── scenarios/
│   └── chat-stream.yaml     # archetype scenario substituted
└── .compose-manifest.json   # sha256s + plan-entry hash for cache invalidation
```

The compose layer is **content-addressed**:

- Fast-path: if every archetype source file's mtime predates the
  manifest's `composed_at`, the cache is trusted as-is.
- Slow-path: any newer mtime triggers a sha256 check. Mismatch →
  recompose.
- Plan-entry edits → recompose (the plan-entry hash is included in the
  manifest).

`.build/` is **always** gitignored. Recompose explicitly with
`mirroir-run --recompose`.

## Project-local archetypes

For organization-specific patterns that don't belong in a public pack:

```
.mirroir/archetypes/my-custom/
├── archetype.md
├── APP.md
├── SKILL.md
└── scenarios/my-flow.yaml
```

Plan entry:

```yaml
- name: my-sample
  archetypes: [./archetypes/my-custom]
  flows: [my-flow]
  boot: { command: "...", boot_ready_port: 8080 }
```

The `./` prefix routes the resolver to the project tree. Versioning is
the repo's own git history; no `@<version>` field is honored.

## Installing archetype packs

```bash
mkdir -p ~/.mirroir/skills
git clone --branch v1.0.0 https://github.com/jfarcand/mirroir-skills \
          ~/.mirroir/skills/mirroir-skills/1.0.0
```

Each installed version is a separate directory; the resolver picks the
right one per `@<version>` constraint + lockfile pin.

## Cross-surface parity (iOS ↔ web)

A `.mirroir/apps/<name>/` sample can hold **two legs of the same flow** and
assert they stay equivalent:

- **Web leg** — the runnable scenario (`scenarios/<flow>.yaml`) with real DOM
  selectors, authored against the running web app by the `mirroir-onboard` skill
  (`.claude/skills/mirroir-onboard/`, the agent + `chrome-devtools-mcp` recorder). `mirroir-run` replays it on Linux CI.
- **iOS leg** — a `target: { kind: ios, app: "…" }` block. `mirroir-run`
  hands it, as one block, to `mirroir-mcp test` on a macOS host with iPhone
  Mirroring connected, and reads back the report it writes; on any other host
  it is refused by name, never skipped. `generate_skill … emit=true` records
  one from a capture on the phone.

Both legs can live in **one scenario**, and the `cross_surface:` step after
them compares a live capture from each:

```yaml
  - target: { kind: web, url: "http://localhost:3000/" }
  # …navigate to the equivalence point…
  - assert_visible: "summary"
  - target: { kind: ios, app: "Safari" }
  - open_url: "http://<lan-host>:3000/"
  - assert_visible: "Summary"
  - cross_surface:
      captures:
        - surface: web
          selector: "[data-test=summary]"
          to: "${MIRROIR_SAMPLE_DIR}/baselines/<flow>.web.txt"
        - surface: ios
          to: "${MIRROIR_SAMPLE_DIR}/baselines/<flow>.ios.txt"
      response_files:
        - "${MIRROIR_SAMPLE_DIR}/baselines/<flow>.web.txt"
        - "${MIRROIR_SAMPLE_DIR}/baselines/<flow>.ios.txt"
      min_similarity: 0.5
```

The web capture scrapes the selector at the step's position in the flow; the
iOS capture is the iOS block's final screen, read by mirroir-mcp's OCR. Each is
written to its `to` before the comparison, so the run that checks the gate is
the run that produces both halves. `to` must be one of `response_files`, a web
capture needs its `selector`, and the scenario must open a block for every
captured surface — `--validate` refuses each of those before anything runs.

`samples/web-fixture/scenarios/parity.yaml` is the web half of this shape
against a committed `parity.ios.txt`, and `runner/tests/cross_surface_gate.rs`
pins the sequence it produces: agree, reword and refuse, accept, refuse again.

Without `captures` the step only **compares** files that already exist, so both
surfaces have to arrive from somewhere else. That is sound when both really do —
`samples/mega-sample/scenarios/cross-surface.yaml` is a lone `cross_surface:`
step comparing two committed fixtures, and neither file needs producing.

Either way, until every compared file exists the parity step **fails closed** — a
missing file is an error, never a silent pass, and so is a file with no text in
it: two blank surfaces score a perfect match, which is exactly what a screen that
yielded no OCR elements would leave behind.

A pair below `min_similarity` is a **failure**: exit 1, with no
`.harness/drift-log.md` row. It is not the DRIFT verdict at exit 65 that a moved
judge response produces — drift is one surface's output changing against its own
recorded baseline, and this is two live surfaces disagreeing with each other.

`min_similarity` is **required** — a gate whose threshold depends on whether you
remembered to type it is not a gate. `0.5` suits iOS↔web phrasing divergence;
raise it for high-entropy screens, and treat low-vocabulary screens (e.g. a bare
login form) with care — a generic token set can clear a low threshold by
coincidence.

`mirroir-run accept` re-records every captured file — the web scrape and the
iOS block's final screen — from the run it just made, and names every compared
file no capture writes instead of overwriting it. A pair still below
`min_similarity` after accept is reported rather than failed. The full loop is
in [drift-and-accept.md](drift-and-accept.md).

> Two surfaces, one grammar. The iOS and web legs are written in the same
> `SkillStep` language, planned together, and tied by `cross_surface`, rather
> than maintained as two bespoke suites. A `web` block runs anywhere; an `ios`
> block runs through mirroir-mcp on macOS.

## Troubleshooting

- **`MirroirConfigNotFound`** — no `.mirroir/mirroir.yaml` in cwd or any
  ancestor. Run from inside a consumer repo, or pass `--config <PATH>`.
- **`MirroirArchetypeNotFound`** — pack not installed at the required
  version. `git clone --branch <tag>` the pack into
  `~/.mirroir/skills/<pack>/<version>/`.
- **`MirroirLockfileStale`** — `mirroir.yaml` and `mirroir.lock` disagree
  under `--locked` / `--frozen`, either on the ref set / version pins or on a
  recorded `checksum:` the archetype tree no longer hashes to. A message
  naming `now hashes to` means the tree's contents moved under an unchanged
  pin. In dev: `mirroir-run accept` (re-records + warns what changed). In CI:
  re-record locally, review `git diff .mirroir/mirroir.lock`, commit it.
- **`MirroirCompositionUnsupported`** — plan entry has `archetypes:`
  with more than one element. v1 supports exactly one ref; cross-archetype
  composition is on the roadmap.
- **`MirroirInvalidArchetypeRef`** — bare name without prefix
  (`dashboard`). Use `mirroir-skills/dashboard@v1`, `./<path>`, or
  `user/dashboard@v1`.
