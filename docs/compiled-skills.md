# Compiled Skills

JIT compilation for UI automation. A compiled skill eliminates OCR from navigation by capturing coordinates, timing, and scroll sequences during a learning run. The compiled file is self-contained — executable without AI, pure input injection plus timing. The one exception is assertion steps, which re-run a real OCR check on replay to actually verify the screen state. Like compiling source to machine code. Compilation works with both YAML and SKILL.md skill formats.

## The Problem

Each OCR-dependent step costs ~500ms (screencapture + Vision OCR). A 10-step skill touching `tap`, `wait_for`, `scroll_to`, and `assert_visible` makes 10+ OCR calls — that's 5+ seconds of OCR overhead alone, on top of actual UI interaction time.

For regression suites running dozens of skills, OCR dominates the total runtime. Worse, OCR introduces non-determinism: text recognition confidence varies between runs, and fuzzy matching can find the wrong element if the screen layout shifts slightly.

## The Solution: Compile Once, Replay Forever

Run the skill once against a real device. The compiler observes everything — which element matched, at what coordinates, with what confidence, how long each `wait_for` took, how many scrolls `scroll_to` needed. It saves all of this into a `.compiled.json` file alongside the source skill file.

On subsequent runs, the test runner detects the compiled file and replays the skill using cached data — zero OCR, zero AI, zero non-determinism.

```
Source:     apps/settings/check-about.md (or .yaml)
Compiled:   apps/settings/check-about.compiled.json
```

## How It Works

There are two ways to compile a skill: AI-driven compilation (recommended) and CLI compilation. Both produce identical `.compiled.json` files.

### AI-Driven Compilation (Recommended)

When an AI agent executes a skill via MCP tools, it already has all the data needed for compilation — tap coordinates from `describe_screen`, timing from step execution, scroll counts from `scroll_to`. Two MCP tools let the AI report this data back to the server:

1. **`record_step`** — called after each step with the step index, type, label, and observed data (coordinates, timing, scroll counts)
2. **`save_compiled`** — called after all steps complete, writes the `.compiled.json` file

The first AI execution IS the compilation. No separate learning run needed.

**How it works:**

1. AI calls `get_skill("check-about")` — response includes compilation status
2. If `[Not compiled]` or `[Compiled: stale]`, the AI calls `record_step` after each step:
   - **tap** steps: includes `tap_x`, `tap_y`, `confidence`, `match_strategy` from `describe_screen`
   - **wait_for** / **assert** steps: includes `elapsed_ms` (approximate time waited)
   - **scroll_to** steps: includes `scroll_count` and `scroll_direction`
   - **launch**, **type**, **press_key**, etc.: just index, type, and label (already OCR-free)
3. After all steps succeed, AI calls `save_compiled("check-about")`
4. Server builds `CompiledSkill`, writes `.compiled.json` next to the source file
5. Next `get_skill("check-about")` returns `[Compiled: fresh]` — AI skips compilation

The server derives `compiledAction` from the reported data:
- `tap` + coordinates → `.tap` (direct coordinate replay)
- `wait_for` + elapsed time → `.sleep` (timed delay)
- `assert_visible` / `assert_not_visible` → `.assertion` (timed delay **plus** a real re-OCR verification)
- `scroll_to` + count/direction → `.scrollSequence` (replayed swipes)
- `launch`, `type`, `press_key`, etc. → `.passthrough` (already OCR-free)

### CLI Compilation (Alternative)

```bash
mirroir compile apps/settings/check-about
```

The CLI compiler:
1. Resolves and parses the skill (YAML or SKILL.md)
2. Wraps the OCR subsystem in a `RecordingDescriber` that caches every result
3. Executes each step against the real device, exactly like `mirroir test`
4. After each step, reads the cached OCR data to build `StepHints`:
   - **tap** → captures exact (x, y) coordinates, confidence score, match strategy
   - **long_press** → captures the same cached (x, y) coordinates as a tap (compiles to `tap`); falls back to `passthrough` if no match was cached
   - **wait_for** → captures elapsed time until the element appeared (`sleep`)
   - **measure** → compiles the observed total time as a `sleep`
   - **assert_visible** / **assert_not_visible** → compiles to an `assertion` (records the observed delay, then re-runs real OCR verification on replay)
   - **scroll_to** → captures number of scrolls and direction used
   - **drag** → marked as `passthrough` (needs two runtime OCR lookups, so it is not pre-resolved)
   - **launch, type, swipe, press_key, home, shake, open_url, reset_app, set_network, switch_target** → marked as `passthrough` (already OCR-free)
   - **screenshot** → marked as `passthrough` (still captures, useful for verification)
5. Saves the compiled JSON with a SHA-256 hash of the source skill

### Replay

```bash
mirroir test apps/settings/check-about
```

The test runner auto-detects `check-about.compiled.json` and uses it:

| Compiled Action | What Happens on Replay |
|----------------|----------------------|
| `tap` | Direct `input.tap(x, y)` at cached coordinates — no OCR. If the cached confidence is below `compiledTapMinConfidence`, replay falls back to live OCR for that step |
| `sleep` | `usleep(observedDelayMs + sleep buffer)` — no polling |
| `assertion` | `usleep(observedDelayMs + sleep buffer)`, then delegates to the normal `StepExecutor` for a real OCR `assert_visible` / `assert_not_visible` check |
| `scroll_sequence` | Replay exact N swipes in the recorded direction |
| `passthrough` | Delegate to normal `StepExecutor` (step was already OCR-free) |

The sleep buffer defaults to 200ms but is configurable via `compiledSleepBufferMs` in `EnvConfig`.

To force full OCR and ignore compiled files:

```bash
mirroir test --no-compiled apps/settings/check-about
```

## File Format

```json
{
  "version": 2,
  "source": {
    "sha256": "a1b2c3...",
    "compiledAt": "2026-02-19T14:30:00Z"
  },
  "device": {
    "windowWidth": 410.0,
    "windowHeight": 898.0,
    "orientation": "portrait"
  },
  "steps": [
    {
      "index": 0,
      "type": "launch",
      "label": "Settings",
      "hints": { "compiledAction": "passthrough" }
    },
    {
      "index": 1,
      "type": "tap",
      "label": "General",
      "hints": {
        "compiledAction": "tap",
        "tapX": 205.0,
        "tapY": 340.5,
        "confidence": 0.98,
        "matchStrategy": "exact"
      }
    },
    {
      "index": 2,
      "type": "wait_for",
      "label": "About",
      "hints": {
        "compiledAction": "sleep",
        "observedDelayMs": 1200
      }
    },
    {
      "index": 3,
      "type": "scroll_to",
      "label": "Model Name",
      "hints": {
        "compiledAction": "scroll_sequence",
        "scrollCount": 3,
        "scrollDirection": "up"
      }
    },
    {
      "index": 4,
      "type": "assert_visible",
      "label": "iPhone",
      "hints": {
        "compiledAction": "assertion",
        "observedDelayMs": 200
      }
    }
  ]
}
```

The optional `screenFingerprint` field (a SHA-256 hash of sorted structural texts plus an icon count) is captured at compile time and used for content-drift detection (see below).

## Staleness Detection

The compiled file is invalidated when any of these change:

| Condition | Result | What Happens |
|-----------|--------|-------------|
| Source skill edited | `stale` | SHA-256 mismatch → warning, falls back to full OCR |
| Window dimensions changed | `stale` | Device mismatch → warning, falls back to full OCR |
| Format version bumped | `stale` | Version mismatch → warning, falls back to full OCR |
| Screen content shifted (e.g. app update) | `drifted` | Live screen fingerprint diverges from the recorded baseline → the CLI **auto-recompiles** the skill on the spot, unless `--no-auto-recompile` is passed (in which case it warns and uses the compiled skill anyway) |

Staleness checks return one of three `StalenessResult` values: `fresh`, `stale`, or `drifted`. A `stale` result is a hard mismatch (source/dimensions/version) that always falls back to full OCR. A `drifted` result is a softer signal — the skill structure and device still match, but the screen content has moved enough that cached coordinates may be wrong; here the runner re-learns the coordinates automatically rather than discarding the compiled data.

When a compiled file is stale, the test runner prints a warning and runs the skill with full OCR. Recompile to update — either by running the skill again via AI (which auto-recompiles when it sees `[Compiled: stale]`) or via the CLI:

```bash
mirroir compile apps/settings/check-about
```

## Where Compiled Files Live

Compiled `.json` files live alongside their source skill files (`.md` or `.yaml`). For skills in the [mirroir-skills](https://github.com/jfarcand/mirroir-skills) repository:

```
mirroir-skills/
  skills/
    apps/
      settings/
        check-about.md                ← source SKILL.md (committed)
        check-about.compiled.json     ← compiled on your machine (not committed)
      clock/
        set-timer.md
        set-timer.compiled.json
```

The mirroir-skills repository commits no compiled files: every user compiles against their own device. In your own skill directories, committing or ignoring them is your choice.

Compiled files are device-specific (coordinates depend on window dimensions). If your team uses different display modes or device models, each device configuration needs its own compilation run.

## What Cannot Be Compiled

AI-only steps (`remember`, `condition`, `repeat`, `verify`, `summarize`) require human interpretation and cannot be compiled. They are recorded with `hints: null` and skipped during compiled replay — same behavior as the normal test runner.

## Architecture

### AI-Driven Compilation (via MCP tools)

```
AI executes skill steps via MCP tools
  ↓
After each step → AI calls record_step(index, type, label, coords/timing)
  ↓
Server accumulates CompiledStep[] in CompilationSession (thread-safe)
  ↓
After all steps → AI calls save_compiled(skill_name)
  ↓
Server builds CompiledSkill, writes .compiled.json next to source
  ↓
mirroir test can now replay with zero OCR
```

### CLI Compilation (via mirroir compile)

```
┌─────────────────────────────────────────────────┐
│  mirroir compile                                │
│                                                 │
│  SkillParser ──→ StepExecutor ──→ BuildHints │
│                       ↑                    ↓    │
│              RecordingDescriber      CompiledJSON│
│              (caches OCR results)                │
└─────────────────────────────────────────────────┘
```

### Replay (both paths produce identical output)

```
┌─────────────────────────────────────────────────┐
│  mirroir test (with compiled)                   │
│                                                 │
│  CompiledStepExecutor                           │
│    tap        → input.tap(x, y)                 │
│    sleep      → usleep(ms + buffer)             │
│    assertion  → usleep + StepExecutor (re-OCR)  │
│    scroll_seq → N × input.swipe(...)            │
│    passthrough→ StepExecutor (normal)           │
│                                                 │
│  Zero AI. Zero OCR except assertion re-checks.  │
└─────────────────────────────────────────────────┘
```

### Key Source Files

| File | Purpose |
|------|---------|
| `Sources/mirroir-mcp/CompilationTools.swift` | MCP tools `record_step` + `save_compiled`, `CompilationSession` state |
| `Sources/mirroir-mcp/CompiledSkill.swift` | Data model: `CompiledSkill`, `CompiledStep`, `StepHints`, file I/O, SHA-256 |
| `Sources/mirroir-mcp/RecordingDescriber.swift` | Decorator that caches OCR results during CLI compilation |
| `Sources/mirroir-mcp/CompileCommand.swift` | CLI `compile` subcommand orchestration |
| `Sources/mirroir-mcp/CompiledStepExecutor.swift` | Replays compiled steps with zero OCR |
| `Tests/MCPServerTests/CompilationToolsTests.swift` | AI-driven compilation session, hint derivation, I/O tests |
| `Tests/TestRunnerTests/CompiledSkillTests.swift` | JSON round-trip, staleness, path derivation tests |
| `Tests/TestRunnerTests/CompiledStepExecutorTests.swift` | Compiled tap, sleep, scroll, passthrough tests |

## Design Rationale

**Why JSON for compiled output?** Compiled skills are machine-generated, machine-consumed. No human writes them. No AI reads them. JSON gives type-safe `Codable` round-trips with zero parsing ambiguity, numeric precision for coordinates, and schema enforcement on decode.

**Why a companion file, not inline annotations?** The source skill stays clean and readable. Compiled data is a build artifact, not source. Keeping them separate means you can gitignore compiled files if you prefer, or commit them for reproducible CI runs.

**Why two compilation paths?** AI-driven compilation eliminates a separate learning run — the first AI execution of a skill IS the compilation. The CLI path (`mirroir compile`) exists for environments where AI is unavailable or when you want to compile without an MCP client.

**Why auto-recompile on drift but not on hard staleness?** Hard staleness (`stale`) means the source skill, window dimensions, or format version changed — the cached coordinates are no longer trustworthy and the safe move is a full-OCR run. Content drift (`drifted`) is different: the skill and device still match, but the screen content moved. Since the runner is already executing against the real device, it re-learns the coordinates in place (unless `--no-auto-recompile` is passed). AI agents likewise auto-recompile when they detect `[Compiled: stale]` in the `get_skill` response.

**Why a configurable sleep buffer (default 200ms) instead of adaptive?** Simplicity. The buffer covers minor timing variance between runs and defaults to 200ms, overridable via `compiledSleepBufferMs`. If a particular step needs more time, edit the YAML to add an explicit `wait_for` before the sensitive step and recompile.
