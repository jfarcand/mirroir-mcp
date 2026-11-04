# Replay anywhere with `mirroir-run`

The Rust runner that replays one scenario across the iPhone, the web, HTTP and subprocesses.

`mirroir-mcp` drives the iPhone — AX + OCR + BFS exploration. `mirroir-run` replays `.mirroir/` SkillStep scenarios against **web, process, HTTP, and iOS** surfaces: web through Playwright, subprocesses and HTTP natively, and each `target: { kind: ios }` block handed to `mirroir-mcp test` on a Mac with iPhone Mirroring connected. Both read one SkillStep grammar, so a single scenario can drive a browser and a phone and check that they show the same thing. A single Rust binary (`runner/` in this repo); web, process and HTTP scenarios run on Linux CI with no macOS dependency. How the two binaries meet: [Web and iOS in one scenario](web-and-ios.md).

Drop a `.mirroir/` directory in any repo and `mirroir-run` discovers it from the working directory:

```
your-app/
└── .mirroir/
    ├── mirroir.yaml          # the plan: must-pass / nice-to-pass entries
    └── apps/<sample>/
        ├── SAMPLE.md         # how to boot the app under test
        ├── APP.md            # structure, obstacles, skip lists
        └── scenarios/*.yaml  # SkillStep flows to replay
```

```bash
cd your-app
mirroir-run                          # discover .mirroir/, replay the must-pass plan
mirroir-run --scenarios all          # include nice-to-pass entries too
```

Each plan entry either points at a `local:` sample tree or extends a shared **archetype** (`archetypes: ["<pack>/<name>@<ver>"]`) with per-instance `vars:` and `boot:`. An archetype captures a reusable app shape — say, an AI chat console — once, and parameterizes it per app.

**Where the iOS leg comes from.** `generate_skill … emit=true` (on `finish` or `explore`), `save_compiled … emit=true` (a skill an AI ran step by step) and `mirroir record` (a walk driven by hand) each write the flow into `.mirroir/apps/<app>/` as a runnable iOS leg: a `target: { kind: ios }` scenario, a `SAMPLE.md` declaring it, and a `must_pass` plan entry. `mirroir-run` hands each `ios` block to `mirroir-mcp test` on a macOS host with iPhone Mirroring connected, and refuses it by name on any other host. Run the MCP from your consumer repo (or pass `output_dir`) so the tree lands in the right `.mirroir/`; emitting into `~/.mirroir` (the runner's pack home) is refused. One scenario can hold both legs: a `web` block, an `ios` block, and a `cross_surface:` step whose `captures:` record the page's scrape and the phone's final screen live, then compare them — the run that checks the gate produces both halves. See [`runner/docs/mirroir-dotfile.md`](../runner/docs/mirroir-dotfile.md).

Web steps compile to a Playwright `.spec.ts` and run across chromium, firefox, and webkit. Selectors resolve three ways: raw CSS, Playwright engine prefixes (`role=button[name="Save"]`, `text=Welcome`, `xpath=…`), or a bare label resolved in Playwright's own priority — role, label, placeholder, `data-test`, visible text. Every compiled spec also collects uncaught page errors and failed responses, so a page that throws is a failure even when every locator resolved. The spec, its config, and the trace / video / screenshot of a failure persist under `target/playwright/<sample>/<scenario>/`. Process and HTTP steps dispatch natively; an LLM judge step scores agent responses against expected signals, and drift detection catches output divergence vs. a baseline.

| Mode | Command |
|---|---|
| Validate a scenario against the grammar | `mirroir-run --validate scenario.yaml` |
| Compile the Playwright spec to disk | `mirroir-run --emit playwright scenario.yaml` |
| Run one scenario end-to-end | `mirroir-run --run-scenario scenario.yaml` |
| Boot a sample dir, run its scenarios | `mirroir-run --sample .mirroir/apps/foo` |
| Hand an iOS block to a specific `mirroir-mcp` | `MIRROIR_MCP_BIN=/path/to/mirroir-mcp mirroir-run …` |
| Standalone text drift check | `mirroir-run --diff-text a.txt b.txt` |

### Install `mirroir-run`

```bash
# crates.io
cargo install mirroir-run

# Homebrew
brew install jfarcand/tap/mirroir-run
```

Prebuilt binaries for macOS (Intel + Apple Silicon), Linux (gnu + musl), and Windows are attached to each [`runner-v*` release](https://github.com/jfarcand/mirroir-mcp/releases). On Windows, subprocess teardown signals are not implemented, so process scenarios are not supported there. See [`runner/docs/`](../runner/docs/) for the scenario grammar, `SAMPLE.md` schema, judge profiles, and CI integration.

### Use `mirroir-run` in GitHub Actions

```yaml
- uses: jfarcand/mirroir-mcp/actions/setup-mirroir-run@main
  with:
    version: latest   # or pin: 0.4.0
- run: mirroir-run    # replays the nearest .mirroir/mirroir.yaml
```

Installs the released `mirroir-run` binary (Linux x64, macOS arm64/x64, Windows x64), verifies its SHA-256 and adds it to `PATH`. Web scenarios also need Playwright: add `jfarcand/mirroir-mcp/.github/actions/setup-playwright@main`. See [`actions/setup-mirroir-run`](../actions/setup-mirroir-run/README.md).

### Bring your Maestro flows

Maestro flows run on a real, stock iPhone through `mirroir-run`:

```bash
mirroir-run import maestro flows/*.yaml -o .mirroir/apps/shop/scenarios \
  --app com.example.shop=Shop
```

Each flow becomes an `<stem>.ios.yaml` scenario, with `runFlow` includes inlined. Commands mirroir cannot run faithfully (id selectors, JavaScript, Android-only keys) fail the import, each listed with its file and line. `--skip-unsupported` imports without them and records each one as a comment. See [`runner/docs/maestro-import.md`](../runner/docs/maestro-import.md) for the full mapping.
