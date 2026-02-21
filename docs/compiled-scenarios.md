# Compiled Scenarios

JIT compilation for UI automation. A compiled scenario eliminates all OCR calls by capturing coordinates, timing, and scroll sequences during a learning run. The compiled file is fully self-contained — executable without AI or OCR, pure input injection plus timing. Like compiling source to machine code. Compilation works with both YAML and SKILL.md scenario formats.

## The Problem

Each OCR-dependent step costs ~500ms (screencapture + Vision OCR). A 10-step scenario touching `tap`, `wait_for`, `scroll_to`, and `assert_visible` makes 10+ OCR calls — that's 5+ seconds of OCR overhead alone, on top of actual UI interaction time.

For regression suites running dozens of scenarios, OCR dominates the total runtime. Worse, OCR introduces non-determinism: text recognition confidence varies between runs, and fuzzy matching can find the wrong element if the screen layout shifts slightly.

## The Solution: Compile Once, Replay Forever

Run the scenario once against a real device in "learning mode." The compiler observes everything — which element matched, at what coordinates, with what confidence, how long each `wait_for` took, how many scrolls `scroll_to` needed. It saves all of this into a `.compiled.json` file alongside the source scenario file.

On subsequent runs, the test runner detects the compiled file and replays the scenario using cached data — zero OCR, zero AI, zero non-determinism.

```
Source:     apps/settings/check-about.md (or .yaml)
Compiled:   apps/settings/check-about.compiled.json
```

## How It Works

### Step 1: Compile

```bash
mirroir compile apps/settings/check-about
```

The compiler:
1. Resolves and parses the scenario (YAML or SKILL.md)
2. Wraps the OCR subsystem in a `RecordingDescriber` that caches every result
3. Executes each step against the real device, exactly like `mirroir test`
4. After each step, reads the cached OCR data to build `StepHints`:
   - **tap** → captures exact (x, y) coordinates, confidence score, match strategy
   - **wait_for** → captures elapsed time until the element appeared
   - **assert_visible** / **assert_not_visible** → captures small observed delay
   - **scroll_to** → captures number of scrolls and direction used
   - **launch, type, swipe, press_key, home, shake, open_url** → marked as `passthrough` (already OCR-free)
   - **screenshot** → marked as `passthrough` (still captures, useful for verification)
5. Saves the compiled JSON with a SHA-256 hash of the source scenario

### Step 2: Replay

```bash
mirroir test apps/settings/check-about
```

The test runner auto-detects `check-about.compiled.json` and uses it:

| Compiled Action | What Happens on Replay |
|----------------|----------------------|
| `tap` | Direct `input.tap(x, y)` at cached coordinates — no OCR |
| `sleep` | `usleep(observedDelayMs + 200ms buffer)` — no polling |
| `scroll_sequence` | Replay exact N swipes in the recorded direction |
| `passthrough` | Delegate to normal `StepExecutor` (step was already OCR-free) |

To force full OCR and ignore compiled files:

```bash
mirroir test --no-compiled apps/settings/check-about
```

## File Format

```json
{
  "version": 1,
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
        "compiledAction": "sleep",
        "observedDelayMs": 200
      }
    }
  ]
}
```

## Staleness Detection

The compiled file is invalidated when any of these change:

| Condition | What Happens |
|-----------|-------------|
| Source scenario edited | SHA-256 mismatch → warning, falls back to full OCR |
| Window dimensions changed | Device mismatch → warning, falls back to full OCR |
| Format version bumped | Version mismatch → warning, falls back to full OCR |

When a compiled file is stale, the test runner prints a warning and runs the scenario with full OCR. Recompile to update:

```bash
mirroir compile apps/settings/check-about
```

There is no auto-recompilation. Compilation requires a real device with the app in the expected state, so it must be triggered explicitly.

## Where Compiled Files Live

Compiled `.json` files live alongside their source scenario files (`.md` or `.yaml`). For scenarios in the [mirroir-scenarios](https://github.com/jfarcand/mirroir-scenarios) repository:

```
mirroir-scenarios/
  apps/
    settings/
      check-about.md                ← source SKILL.md (committed)
      check-about.compiled.json     ← compiled (committed or gitignored, your choice)
    clock/
      set-timer.md
      set-timer.compiled.json
```

Compiled files are device-specific (coordinates depend on window dimensions). If your team uses different display modes or device models, each device configuration needs its own compilation run.

## What Cannot Be Compiled

AI-only steps (`remember`, `condition`, `repeat`, `verify`, `summarize`) require human interpretation and cannot be compiled. They are recorded with `hints: null` and skipped during compiled replay — same behavior as the normal test runner.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  mirroir compile                                │
│                                                 │
│  ScenarioParser ──→ StepExecutor ──→ BuildHints │
│                       ↑                    ↓    │
│              RecordingDescriber      CompiledJSON│
│              (caches OCR results)                │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  mirroir test (with compiled)                   │
│                                                 │
│  CompiledStepExecutor                           │
│    tap        → input.tap(x, y)                 │
│    sleep      → usleep(ms + buffer)             │
│    scroll_seq → N × input.swipe(...)            │
│    passthrough→ StepExecutor (normal)           │
│                                                 │
│  Zero OCR calls. Zero AI.                       │
└─────────────────────────────────────────────────┘
```

### Key Source Files

| File | Purpose |
|------|---------|
| `Sources/mirroir-mcp/CompiledScenario.swift` | Data model: `CompiledScenario`, `CompiledStep`, `StepHints`, file I/O, SHA-256 |
| `Sources/mirroir-mcp/RecordingDescriber.swift` | Decorator that caches OCR results during compilation |
| `Sources/mirroir-mcp/CompileCommand.swift` | CLI `compile` subcommand orchestration |
| `Sources/mirroir-mcp/CompiledStepExecutor.swift` | Replays compiled steps with zero OCR |
| `Tests/TestRunnerTests/CompiledScenarioTests.swift` | JSON round-trip, staleness, path derivation tests |
| `Tests/TestRunnerTests/CompiledStepExecutorTests.swift` | Compiled tap, sleep, scroll, passthrough tests |

## Design Rationale

**Why JSON for compiled output?** Compiled scenarios are machine-generated, machine-consumed. No human writes them. No AI reads them. JSON gives type-safe `Codable` round-trips with zero parsing ambiguity, numeric precision for coordinates, and schema enforcement on decode.

**Why a companion file, not inline annotations?** The source scenario stays clean and readable. Compiled data is a build artifact, not source. Keeping them separate means you can gitignore compiled files if you prefer, or commit them for reproducible CI runs.

**Why no auto-recompile on staleness?** Compilation requires a real device with the app in the correct starting state. Auto-recompiling on a mismatched hash could produce wrong coordinates if the app changed. Explicit compilation gives the operator control over when and how the learning run happens.

**Why a fixed sleep buffer (200ms) instead of adaptive?** Simplicity. The buffer covers minor timing variance between runs. If a particular step needs more time, edit the YAML to add an explicit `wait_for` before the sensitive step and recompile.
