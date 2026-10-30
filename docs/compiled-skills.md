# Compiled Skills

JIT compilation for UI automation. A compiled skill captures coordinates, timing, and scroll sequences during a learning run, so replay needs no AI and no element search beyond one check per step. Replay is never blind: a step that did not do what it says fails. A labeled tap checks its element by OCR before tapping, a tap recorded by coordinates alone must reach the screen it reached when recorded, `wait_for` polls the screen live, `scroll_to` requires its target on screen after the recorded swipes, and assertions re-run their OCR check. Compilation works with both YAML and SKILL.md skill formats.

## The Problem

Each OCR-dependent step pays for a screen capture plus Vision OCR. Through the MCP server that is about 200ms per screen read. Under `mirroir test` on 2026-10-27, a live screen read on a real device took about 10.8s: ScreenCaptureKit released its completion handler unanswered, and the capture waited out a 10s timeout before falling back to the `screencapture` CLI. A dropped handler now falls back at once, and every run ends with a `capture: sck=N fallback=M` line, so a degraded capture path shows in the output rather than only as slow steps. A 10-step skill touching `tap`, `wait_for`, `scroll_to`, and `assert_visible` makes 10+ screen reads, on top of actual UI interaction time.

For regression suites running dozens of skills, OCR dominates the total runtime. Worse, OCR introduces non-determinism: text recognition confidence varies between runs, and fuzzy matching can find the wrong element if the screen layout shifts slightly.

## The Solution: Compile Once, Replay Forever

Run the skill once against a real device. The compiler observes everything — which element matched, at what coordinates, how long each `wait_for` took, how many scrolls `scroll_to` needed. It saves all of this into a `.compiled.json` file alongside the source skill file.

On subsequent runs, the test runner detects the compiled file and replays the skill using cached data, with no AI. Every step is still checked against the screen: a labeled tap or `scroll_to` makes one OCR read to verify its element, assertions re-run OCR, and `wait_for` and every `passthrough` step run live.

```
Source:     apps/settings/check-about.md (or .yaml)
Compiled:   apps/settings/check-about.compiled.json
```

## How It Works

There are two ways to compile a skill: AI-driven compilation (recommended) and CLI compilation. Both produce identical `.compiled.json` files.

### AI-Driven Compilation (Recommended)

When an AI agent executes a skill via MCP tools, it already has all the data needed for compilation — tap coordinates from `describe_screen`, timing from step execution, scroll counts from `scroll_to`. Two MCP tools let the AI report this data back to the server:

1. **`record_step`** — called after each step with the step index, type, label, and observed data (coordinates, timing, scroll counts). For a tap with coordinates and no label, it also reads the settled screen the tap led to and stores it as the hint's `arrivalFingerprint`; the step is refused when that screen cannot be read, shows fewer than `compiledTapArrivalMinTexts` labels, or a later step is already recorded (the screen on display is then not the tap's destination)
2. **`save_compiled`** — called after all steps complete, writes the `.compiled.json` file

The first AI execution IS the compilation. No separate learning run needed.

**How it works:**

1. AI calls `get_skill("check-about")` before running step 1 — response includes compilation status, and the server fingerprints the current screen (local OCR) as the screen the skill starts from
2. If `[Not compiled]` or `[Compiled: stale]`, the AI calls `record_step` after each step:
   - **tap** steps: includes `tap_x`, `tap_y`, `match_strategy` from `describe_screen`
   - **assert** steps: includes `elapsed_ms` (approximate time waited)
   - **wait_for** steps: just index, type, and label (they replay live, polling for the element)
   - **scroll_to** steps: includes `scroll_count` and `scroll_direction`
   - **launch**, **type**, **press_key**, **target**, **long_press**, **drag**, etc.: just index, type, and label
   - every step's `label` is its value as the skill writes it (`l+command`, `"Photo" duration: 1500`, `{ kind: ios, app: "Notes" }`): a SKILL.md replays from these. `record_step` records every step, and notes when `mirroir test` cannot replay one (a tool with no skill step type, such as `press_back`); that skill is then refused by `mirroir test` with the reason
3. After all steps succeed, AI calls `save_compiled("check-about")`. It refuses a gap in the recorded step indices, and for a SKILL.md a step that could not replay as recorded (a missing value, a drag without both ends, a measure without an action or `until:`), keeping the session so the AI can record those steps again
4. Server builds `CompiledSkill` with the start-screen fingerprint `get_skill` read, writes `.compiled.json` next to the source file (a skill saved without that `get_skill` call gets no fingerprint, never the screen the run ended on)
5. Next `get_skill("check-about")` returns `[Compiled: fresh]` — AI skips compilation

The server derives `compiledAction` from the reported data:
- `tap` + coordinates → `.tap` (a labeled tap is checked by OCR finding its element; a tap with no label records `arrivalFingerprint`, the screen it led to, which replay must reach)
- `wait_for` → `.passthrough` (polls the screen live until the element shows or its timeout passes)
- `assert_visible` / `assert_not_visible` → `.assertion` (timed delay **plus** a real re-OCR verification)
- `scroll_to` + count/direction → `.scrollSequence` (replayed swipes)
- `launch`, `type`, `press_key`, etc. → `.passthrough` (run live; these need no OCR)
- `tap` without coordinates, `target`, `long_press`, `drag` → `.passthrough` (run live by the normal executor)

### CLI Compilation (Alternative)

```bash
mirroir compile apps/settings/check-about
```

The CLI compiler:
1. Resolves and parses the skill (YAML or SKILL.md)
2. Wraps the OCR subsystem in a `RecordingDescriber` that caches every result
3. Fingerprints the screen before the first step runs: the screen the skill starts from
4. Executes each step against the real device, exactly like `mirroir test`
5. After each step, reads the cached OCR data to build `StepHints`:
   - **tap** → captures exact (x, y) coordinates and match strategy; a tap with no cached match is marked `passthrough`
   - **long_press** → marked as `passthrough` (a compiled tap would replay it as a short tap)
   - **wait_for** → marked as `passthrough` (a recorded delay would pass without looking at the screen; live, it polls until the element shows or its timeout passes)
   - **measure** → marked as `passthrough` (a recorded delay would pass without running its action or its `until` check)
   - **assert_visible** / **assert_not_visible** → compiles to an `assertion` (records the observed delay, then re-runs real OCR verification on replay)
   - **scroll_to** → captures number of scrolls and direction used
   - **drag** → marked as `passthrough` (needs two runtime OCR lookups, so it is not pre-resolved)
   - **launch, type, swipe, press_key, home, shake, open_url, reset_app, set_network, target** → marked as `passthrough` (nothing to pre-resolve; a `type` that pastes still OCR-confirms each paste)
   - **screenshot** → marked as `passthrough` (still captures, useful for verification)
6. Saves the compiled JSON with a SHA-256 hash of the source skill

### Replay

```bash
mirroir test apps/settings/check-about
```

The test runner auto-detects `check-about.compiled.json` and uses it:

| Compiled Action | What Happens on Replay |
|----------------|----------------------|
| `tap` | A labeled tap reads the screen once. Its element within `compiledTapPositionTolerance` points (per axis) of the recorded spot → `input.tap(x, y)` at the cached coordinates. Found elsewhere → tapped where it is now, and the step message names both positions. Not found → the step **fails** without tapping. A tap recorded by coordinates alone (an icon with no text) has nothing to find before it, so it is checked after: replay reads the screen first and does not tap when it already matches `arrivalFingerprint` (the screen the tap reached when recorded), since then even a dropped tap would look right. Otherwise it taps the cached coordinates and polls until the screen matches `arrivalFingerprint`, up to the `wait_for` timeout, else the step **fails**. Screens are compared on their multi-character structural texts (keyboard letters do not count); a destination with fewer than `compiledTapArrivalMinTexts` of them, or no recorded `arrivalFingerprint`, fails without tapping |
| `assertion` | `usleep(observedDelayMs + sleep buffer)`, then delegates to the normal `StepExecutor` for a real OCR `assert_visible` / `assert_not_visible` check |
| `scroll_sequence` | Replay exact N swipes in the recorded direction, then read the screen: the target visible → pass. Missing → one extra swipe in the same direction and another read; still missing → the step **fails** |
| `passthrough` | Delegate to normal `StepExecutor`, which runs the step live (`wait_for` polls until its element shows or its timeout passes) |

A `tap` or `scroll_sequence` hint paired with a different kind of step (a compiled file that no longer describes its skill) fails that step and asks for a recompile.

The assertion sleep buffer defaults to 200ms but is configurable via `compiledSleepBufferMs` in `EnvConfig`.

To force full OCR and ignore compiled files:

```bash
mirroir test --no-compiled apps/settings/check-about
```

## File Format

```json
{
  "version": 5,
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
        "matchStrategy": "exact"
      }
    },
    {
      "index": 2,
      "type": "wait_for",
      "label": "About",
      "hints": { "compiledAction": "passthrough" }
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

The optional `screenFingerprint` field (a SHA-256 hash of sorted structural texts plus an icon count) is the screen the skill starts from, read before its first step. Both producers record that same moment: `mirroir compile` and `get_skill` → `save_compiled`. `mirroir test` never compares or rewrites it; it is the baseline a caller compares the screen a run starts on against.

A step's `label` is its replay value: the step's value written the way the skill parser reads it back (`General`, `l+command`, `"About" timeout: 30`, `{ from: "A", to: "B" }`), keeping any `${VAR}` placeholder. A SKILL.md's steps are rebuilt from `type` and `label` when `mirroir test` replays it.

## Staleness Detection

The compiled file is invalidated when any of these change:

| Condition | Result | What Happens |
|-----------|--------|-------------|
| Source skill edited | `stale` | SHA-256 mismatch → warning, falls back to full OCR |
| Window dimensions changed | `stale` | Device mismatch → warning, falls back to full OCR |
| Format version bumped | `stale` | Version mismatch → warning, falls back to full OCR |

Staleness checks return one of two `StalenessResult` values: `fresh` or `stale`. The screen content is not a staleness signal: `mirroir test` reads compiled files and never writes one, so a run cannot quietly re-bless a changed screen.

When a compiled file is stale, the test runner prints a warning and runs the skill with full OCR. Recompile to update — either by running the skill again via AI (which records the steps again when it sees `[Compiled: stale]`) or via the CLI:

```bash
mirroir compile apps/settings/check-about
```

A SKILL.md is the exception. Its compiled file holds the only replayable copy of its steps, so:

- edited since it was compiled, or compiled by an older format version, it is **refused** rather than run with full OCR, and `mirroir compile` cannot recompile it either: run it again through an MCP client;
- a window-size change still falls back to full OCR, replaying the recorded steps live.

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

AI-only steps (`remember`, `condition`, `repeat`, `verify`, `summarize`) need an AI to interpret them and cannot be compiled. They are recorded with `hints: null`. `mirroir test` has no AI client, so it reports each one as `NOT EVALUATED` (`not evaluated: <step> needs an AI client`) and the skill fails, live or compiled; the steps after it still run.

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
mirroir test can now replay without AI, verifying each step
```

### CLI Compilation (via mirroir compile)

```
┌─────────────────────────────────────────────────┐
│  mirroir compile                                │
│                                                 │
│  SkillFileLoader ─→ StepExecutor ─→ BuildHints│
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
│    tap        → OCR check, then input.tap(x, y) │
│    assertion  → usleep + StepExecutor (re-OCR)  │
│    scroll_seq → N × input.swipe + OCR check     │
│    passthrough→ StepExecutor (live, wait_for)   │
│                                                 │
│  Zero AI. A step the screen does not show fails.│
└─────────────────────────────────────────────────┘
```

### Key Source Files

| File | Purpose |
|------|---------|
| `Sources/mirroir-mcp/CompilationTools.swift` | MCP tools `record_step` + `save_compiled` |
| `Sources/mirroir-mcp/CompilationSession.swift` | `CompilationSession`: recorded steps and the start-screen fingerprint `get_skill` reads |
| `Sources/mirroir-mcp/CompiledSkill.swift` | Data model: `CompiledSkill`, `CompiledStep`, `StepHints`, file I/O, SHA-256 |
| `Sources/mirroir-mcp/RecordingDescriber.swift` | Decorator that caches OCR results during CLI compilation |
| `Sources/mirroir-mcp/CompileCommand.swift` | CLI `compile` subcommand orchestration |
| `Sources/mirroir-mcp/SkillFileLoader.swift` | Loads a skill for `test`/`compile`: YAML from its steps, SKILL.md from its `.compiled.json` |
| `Sources/mirroir-mcp/CompiledStepExecutor.swift` | Replays compiled steps from their hints, verifying each on the live screen |
| `Tests/MCPServerTests/CompilationToolsTests.swift` | AI-driven compilation session, hint derivation, I/O tests |
| `Tests/TestRunnerTests/CompiledSkillTests.swift` | JSON round-trip, staleness, path derivation tests |
| `Tests/TestRunnerTests/CompiledStepExecutorTests.swift` | Coordinate-only tap, assertion, scroll, passthrough tests |
| `Tests/TestRunnerTests/CompiledReplayVerificationTests.swift` | Replay verification: labeled tap at spot / moved / absent, live `wait_for`, `scroll_to` target check |

## Design Rationale

**Why JSON for compiled output?** Compiled skills are machine-generated, machine-consumed. No human writes them. No AI reads them. JSON gives type-safe `Codable` round-trips with zero parsing ambiguity, numeric precision for coordinates, and schema enforcement on decode.

**Why a companion file, not inline annotations?** The source skill stays clean and readable. Compiled data is a build artifact, not source. Keeping them separate means you can gitignore compiled files if you prefer, or commit them for reproducible CI runs.

**Why two compilation paths?** AI-driven compilation eliminates a separate learning run — the first AI execution of a skill IS the compilation. The CLI path (`mirroir compile`) exists for environments where AI is unavailable or when you want to compile without an MCP client. It compiles a YAML skill from its steps; a SKILL.md's body is prose for an AI, so the CLI runners (`mirroir test` and `mirroir compile`) take a SKILL.md's steps from its existing `.compiled.json`, rebuilding each from its recorded type and label. That makes `record_step`'s `label` the step's value (the app to launch, the text to type, the key to press), and the first compile of a SKILL.md always the AI-driven one. A SKILL.md with no compiled file, or one edited since, is refused with that instruction.

**Why does `mirroir test` never rewrite a compiled file?** A test run that re-recorded its own baseline whenever the screen changed would accept every change it was meant to catch, and the change would never reach the report or the exit code. Hard staleness (`stale`) means the source skill, window dimensions, or format version changed — the cached coordinates are no longer trustworthy and the safe move is a full-OCR run. Recompiling is an explicit act: `mirroir compile`, or an AI that records the steps again when `get_skill` answers `[Compiled: stale]`.

**Why a configurable assertion sleep buffer (default 200ms) instead of adaptive?** Simplicity. The buffer covers minor timing variance between runs and defaults to 200ms, overridable via `compiledSleepBufferMs`. If a particular step needs more time, edit the YAML to add an explicit `wait_for` before the sensitive step and recompile: a `wait_for` polls live, so it waits exactly as long as the screen needs.

**Why does replay still read the screen?** A replay that taps recorded coordinates and sleeps recorded delays passes whether or not the app did anything: a moved button, a slow screen, or a different page all pass silently. One OCR read per labeled tap and per `scroll_to` is the price of a step that fails when the screen does not show what it says. Compiled replay still saves the search: no AI, no scrolling hunt, and no waiting longer than the screen needs.
