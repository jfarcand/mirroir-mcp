# Contributing to iPhone Mirroir MCP

Thank you for your interest in contributing! By submitting a contribution, you agree to the [Contributor License Agreement](CLA.md). Your Git commit metadata (name and email) serves as your electronic signature.

## Getting Started

1. Fork the repository and clone your fork
2. Run the [installer](mirroir.sh) to build the server binary
3. Read this guide to understand the system
4. Create a feature branch for your work

## Project Structure

```
mirroir-mcp/
├── Sources/
│   ├── mirroir-mcp/           # MCP server + CLI subcommands (~155 files)
│   │   │
│   │   │── # ── Core Infrastructure ──
│   │   ├── mirroir_mcp.swift        # Entry point, CLI dispatch, target registry init
│   │   ├── MCPServer.swift          # JSON-RPC 2.0 server (stdin/stdout)
│   │   ├── ToolHandlers.swift       # Tool registration orchestrator (delegates to *Tools.swift)
│   │   ├── Protocols.swift          # All DI protocol abstractions (WindowBridging, InputProviding, etc.)
│   │   ├── DebugLog.swift           # Debug logging to stderr + ~/.mirroir-mcp/debug.log
│   │   │
│   │   │── # ── Tool Registration (one file per category, thin handlers) ──
│   │   ├── ScreenTools.swift        # screenshot, describe_screen, recording
│   │   ├── InputTools.swift         # tap, swipe, drag, type_text, press_key, long_press, double_tap, shake
│   │   ├── NavigationTools.swift    # launch_app, open_url, press_home, press_app_switcher, press_back, spotlight
│   │   ├── ScrollToTools.swift      # scroll_to
│   │   ├── AppManagementTools.swift # reset_app
│   │   ├── MeasureTools.swift       # measure
│   │   ├── NetworkTools.swift       # set_network
│   │   ├── InfoTools.swift          # status, get_orientation, check_health
│   │   ├── SkillTools.swift         # list_skills, get_skill
│   │   ├── TargetTools.swift        # list_targets, switch_target
│   │   ├── GenerateSkillTools.swift # generate_skill (session-based + autonomous BFS)
│   │   ├── CompilationTools.swift   # record_step, save_compiled
│   │   ├── ComponentTools.swift     # calibrate_component
│   │   │
│   │   │── # ── Window & Target Management ──
│   │   ├── MirroringBridge.swift    # iPhone Mirroring window: AX discovery + menu actions
│   │   ├── GenericWindowBridge.swift # Non-iPhone windows (emulators, VNC, etc.)
│   │   ├── TargetRegistry.swift     # Multi-target registry (active target switching)
│   │   ├── TargetConfig.swift       # targets.json loader
│   │   ├── WindowListHelper.swift   # CGWindowList enumeration helper
│   │   │
│   │   │── # ── Input (CGEvent-based) ──
│   │   ├── CGEventInput.swift       # CGEvent posting for pointing + keyboard
│   │   ├── CGKeyMap.swift           # Character → macOS virtual keycode mapping
│   │   ├── InputSimulation.swift    # Input facade: coordinate mapping + focus management
│   │   ├── InputSimulationKeyboard.swift # Keyboard, shake, app-level operations
│   │   │
│   │   │── # ── Screen Capture & OCR ──
│   │   ├── ScreenCapture.swift      # screencapture -l wrapper
│   │   ├── ScreenDescriber.swift    # OCR orchestration (Vision + optional YOLO)
│   │   ├── AppleVisionTextRecognizer.swift # Apple Vision OCR backend
│   │   ├── CompositeTextRecognizer.swift   # Merge Vision + YOLO results
│   │   ├── CoreMLElementDetector.swift     # YOLO CoreML element detection
│   │   ├── IconDetector.swift       # Unlabeled icon detection via pixel clustering
│   │   ├── IconClusterDetector.swift # Cluster nearby icons
│   │   ├── ScreenRecorder.swift     # Video recording state machine
│   │   ├── RecordingDescriber.swift # ScreenDescribing decorator that caches OCR results
│   │   │
│   │   │── # ── Autonomous Exploration ──
│   │   ├── BFSExplorer.swift        # Breadth-first exploration (default, frontier queue + path replay)
│   │   ├── BFSExplorerHelpers.swift # Calibration, plan resolution, scroll support
│   │   ├── BFSExplorerTypes.swift   # BFS value types (FrontierScreen, PathSegment, Phase)
│   │   ├── BFSBacktrackVerifier.swift # Post-backtrack verification and modal recovery
│   │   ├── DFSExplorer.swift        # Depth-first exploration with backtrack stack
│   │   ├── DFSExplorerBacktrack.swift # DFS backtracking logic
│   │   ├── NavigationGraph.swift    # Directed screen graph (nodes=screens, edges=transitions)
│   │   ├── ExplorationSession.swift # Thread-safe session accumulator
│   │   ├── ExplorationBudget.swift  # Budget tracking (depth, screens, time)
│   │   ├── ExplorerUtilities.swift  # Shared exploration utilities
│   │   ├── GraphPathFinder.swift    # Path finding in navigation graph
│   │   │
│   │   │── # ── Screen Planning & Navigation ──
│   │   ├── ScreenPlanner.swift      # Plan next actions from OCR + components
│   │   ├── PlanCoordinateResolver.swift # Resolve plan items to viewport coordinates
│   │   ├── FrontierPlanner.swift    # Frontier-based planning
│   │   ├── ExplorationGuide.swift   # AI-assisted exploration guidance
│   │   ├── ScoutPhase.swift         # Scout phase for element classification
│   │   │
│   │   │── # ── Component Detection ──
│   │   ├── ComponentLoader.swift    # Discover and load .md component definitions
│   │   ├── ComponentDetector.swift  # Group OCR elements into UI components
│   │   ├── ComponentCatalog.swift   # Component definition library
│   │   ├── ComponentScoring.swift   # Score definitions against OCR row properties
│   │   ├── ComponentTester.swift    # Test components against live screen
│   │   ├── ComponentSkillParser.swift # Parse component SKILL.md definitions
│   │   │
│   │   │── # ── Detection & Classification ──
│   │   ├── ElementClassifier.swift  # Classify OCR elements by role (navigation, info, etc.)
│   │   ├── EdgeClassifier.swift     # Classify navigation edge types (push/pop/replace)
│   │   ├── AlertDetector.swift      # Detect iOS system alert dialogs
│   │   ├── AppContextDetector.swift # Detect app context for recovery
│   │   ├── SpotlightDetector.swift  # Detect Spotlight search state
│   │   ├── StrategyDetector.swift   # Auto-detect exploration strategy (mobile/social/desktop)
│   │   ├── StructuralFingerprint.swift # Screen fingerprinting via Jaccard similarity
│   │   ├── ScrollAnchorDetector.swift  # Detect scroll anchors
│   │   ├── ScrollDeduplicator.swift    # Deduplicate scrolled content
│   │   ├── OverlapDeduplicator.swift   # Deduplicate overlapping OCR elements
│   │   │
│   │   │── # ── Skill System ──
│   │   ├── SkillMdParser.swift      # SKILL.md front matter + body parser
│   │   ├── SkillMdGenerator.swift   # Generate SKILL.md from explored screens
│   │   ├── SkillParser.swift        # YAML → structured SkillStep list
│   │   ├── SkillBundleGenerator.swift # Generate multi-skill bundles
│   │   ├── SkillManifestGenerator.swift # Generate skill manifests
│   │   ├── ActionStepFormatter.swift # Format action steps for SKILL.md
│   │   ├── LandmarkPicker.swift     # Pick OCR landmarks for skill steps
│   │   │
│   │   │── # ── Compiled Skills (zero-OCR replay) ──
│   │   ├── CompiledSkill.swift      # Compiled skill data model + SHA-256
│   │   ├── CompiledStepExecutor.swift # Replay compiled steps (OCR-verified)
│   │   ├── TestRunnerCompiled.swift # Test compiled skills
│   │   │
│   │   │── # ── Test Runner & Recording ──
│   │   ├── TestRunner.swift         # `mirroir test` orchestrator
│   │   ├── StepExecutor.swift       # Run steps against real subsystems
│   │   ├── StepExecutorActions.swift # Step action implementations
│   │   ├── ElementMatcher.swift     # Fuzzy OCR text matching
│   │   ├── ConsoleReporter.swift    # Terminal output formatting
│   │   ├── JUnitReporter.swift      # JUnit XML generation
│   │   ├── EventRecorder.swift      # CGEvent tap monitoring
│   │   ├── YAMLGenerator.swift      # Recorded events → skill YAML
│   │   │
│   │   │── # ── AI Integration ──
│   │   ├── AIAgentProvider.swift    # AI agent abstraction
│   │   ├── AnthropicProvider.swift  # Claude API integration
│   │   ├── OpenAIProvider.swift     # GPT API integration
│   │   ├── OllamaProvider.swift     # Local Ollama integration
│   │   ├── EmbacleProvider.swift    # embacle-server integration
│   │   ├── CommandProvider.swift    # CLI command-based AI provider
│   │   ├── AgentDiagnostic.swift    # AI-assisted test failure diagnosis
│   │   │
│   │   │── # ── CLI Subcommands ──
│   │   ├── CompileCommand.swift     # mirroir compile
│   │   ├── RecordCommand.swift      # mirroir record
│   │   ├── MigrateCommand.swift     # mirroir migrate (YAML → SKILL.md)
│   │   ├── DoctorCommand.swift      # mirroir doctor
│   │   ├── ConfigureCommand.swift   # mirroir configure (keyboard layout)
│   │   │
│   │   │── # ── App Exploration Strategies ──
│   │   ├── MobileAppStrategy.swift  # iOS app exploration heuristics
│   │   ├── DesktopAppStrategy.swift # Desktop app exploration
│   │   └── SocialAppStrategy.swift  # Social media app exploration
│   │
│   ├── HelperLib/                   # Shared library (linked into main + tests)
│   │   ├── MCPProtocol.swift        # JSON-RPC + MCP types (JSONValue, tool defs)
│   │   ├── PermissionPolicy.swift   # Fail-closed permission engine
│   │   ├── EnvConfig.swift          # Centralized settings (settings.json + env vars)
│   │   ├── EnvConfigFeatures.swift  # Feature-specific config properties
│   │   ├── EnvConfigDump.swift      # Dump effective config at startup
│   │   ├── TimingConstants.swift    # Default timing values
│   │   ├── KeyName.swift            # Named key normalization
│   │   ├── AppleScriptKeyMap.swift  # macOS virtual key codes
│   │   ├── LayoutMapper.swift       # Non-US keyboard layout translation
│   │   ├── TapPointCalculator.swift # Smart OCR tap coordinate offset
│   │   ├── GridOverlay.swift        # Coordinate grid overlay on screenshots
│   │   ├── ContentBoundsDetector.swift # Detect iPhone content bounds
│   │   ├── NavigationHintDetector.swift # Detect back chevrons and nav patterns
│   │   ├── ProcessExtensions.swift  # Timeout-aware Process.wait
│   │   ├── AppMdSectioning.swift    # Split APP.md into named sections
│   │   ├── SimulatorSpec.swift      # Simulator app model (screens, elements, obstacles)
│   │   └── SimulatorSpecParser.swift # Parse an APP.md `## Simulator` block into a SimulatorSpec
│   │
│   └── FakeMirroring/               # Test double app for CI (not a mock — a real macOS app)
│       ├── main.swift               # Entry point + window/input bootstrap
│       ├── AppDelegate.swift        # Window setup, AppPack loading, menu bar (Scenario menu)
│       ├── AppPack.swift            # One loaded simulator app (a parsed SimulatorSpec)
│       ├── AppRegistry.swift        # Registry of loaded AppPacks; brokers Spotlight launches
│       ├── SceneRenderer.swift      # SimulatorScreen + obstacle → ScenarioData render payload
│       ├── ScenarioData.swift       # Render-time data shape consumed by the draw pipeline
│       ├── FakeScreenDrawing.swift  # Renders OCR-detectable text labels, cards, tab bars
│       ├── FakeScreenView+AppPack.swift # View glue that draws the active AppPack scene
│       ├── AppSwitcherOverlay.swift # App Switcher card overlay
│       └── SpotlightOverlay.swift   # Spotlight search overlay
│
├── Tests/
│   ├── MCPServerTests/        # XCTest — server routing, tool handlers, exploration (94 files)
│   ├── HelperLibTests/        # Swift Testing — shared library utilities (11 files)
│   ├── TestRunnerTests/       # Swift Testing — test runner, recorder, skill parser (14 files)
│   ├── IntegrationTests/      # XCTest — FakeMirroring integration, requires running app (15 files)
│   └── Fixtures/              # Test skill files (YAML + SKILL.md)
│
├── docs/                      # User-facing documentation
├── scripts/                   # Build/install/CI scripts
└── .githooks/                 # Active git hooks (core.hooksPath): commit-msg + pre-commit
```

## Build & Test

### Commands

| Task | Command |
|------|---------|
| Build | `swift build` |
| Build release | `swift build -c release` |
| Run all tests | `swift test` |
| Run specific test | `swift test --filter <TestClassName>/<testMethodName>` |
| Clean | `swift package clean` |
| Resolve dependencies | `swift package resolve` |

### Tiered Validation

**Tier 1 — Quick Iteration** (during development):
```bash
swift build
swift test --filter <TestClassName>/<testMethodName>
```

**Tier 2 — Pre-Commit** (before committing):
```bash
swift build
swift test --skip IntegrationTests
```

**Tier 3 — Full Validation** (before merge):
```bash
swift build -c release
swift test --skip IntegrationTests
```

### Git Hooks

The active hooks live in **`.githooks/`** (that's where `core.hooksPath` points):

**`.githooks/commit-msg`** — enforces commit message format:
1. **Conventional commit format** — messages must match `type(scope): description` (e.g., `feat: add check_health tool`, `fix(bfs): handle scroll edge case`)
2. **Max 2 lines** — subject + optional blank line + body
3. **No AI assistant references** — rejects `Co-Authored-By: Claude` lines

**`.githooks/pre-commit`** — enforces code quality:
1. **Apache 2.0 license headers** on all Swift files (except `Package.swift`)
2. **ABOUTME headers** — every non-test Swift file must have a 2-line ABOUTME comment
3. **No suspicious files** — blocks `.bak`, `.orig`, `.tmp`, `.swp` files
4. **Swift build** — compilation must succeed
5. **MCP compliance** — validates protocol version, server name, and tool schema (when MCP files change)

Set up the hooks:
```bash
git config core.hooksPath .githooks
```

### Limitation Register

Deferral/confession prose ("not yet wired", "is the follow-up", "for now, return")
is banned in production sources — Swift and Rust alike. The only exemption is a
`LIMITATION(registre#n):` marker naming the limited item and pointing at an issue
in the private register configured by `registre.toml`. The gates (the
[llm-registre](https://github.com/dravr-ai/llm-registre) `.registre` submodule)
also enforce the 500-line file cap and the inline clippy allow-list, at pre-push
(Tier 1 of `runner/scripts/ci/pre-push-validate.sh`) and in CI
(`limitation-register.yml`):

```bash
git submodule update --init   # once, after clone
brew install ripgrep          # the gates are ripgrep-based
./.registre/limitation-gates.sh Sources runner/src npm scripts website/src
```

## How to Add a New MCP Tool

Follow these steps to add a new tool. This example adds a hypothetical `pinch_zoom` tool.

### Step 1: Classify the Tool

Decide if the tool is **readonly** (observation) or **mutating** (changes iPhone state).

In `Sources/HelperLib/PermissionPolicy.swift`, add the tool name to the appropriate set:

```swift
// Mutating — requires explicit permission
public static let mutatingTools: Set<String> = [
    // ... existing tools ...
    "pinch_zoom",
]
```

### Step 2: Add Protocol Method

If the tool needs a protocol abstraction (most input tools do), add a method to the relevant protocol in `Sources/mirroir-mcp/Protocols.swift`:

```swift
protocol InputProviding: Sendable {
    // ... existing methods ...
    func pinchZoom(x: Double, y: Double, scale: Double) -> String?
}
```

### Step 3: Implement the Method

Add the implementation to `InputSimulation`:

```swift
func pinchZoom(x: Double, y: Double, scale: Double) -> String? {
    // Coordinate mapping, CGEvent posting, etc.
}
```

### Step 4: Register the Tool

Add the `MCPToolDefinition` in the appropriate category file (e.g., `InputTools.swift`):

```swift
server.registerTool(MCPToolDefinition(
    name: "pinch_zoom",
    description: "Pinch to zoom at a specific point",
    inputSchema: [
        "type": .string("object"),
        "properties": .object([
            "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
            "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
            "scale": .object(["type": .string("number"), "description": .string("Zoom scale factor")]),
        ]),
        "required": .array([.string("x"), .string("y"), .string("scale")]),
    ],
    handler: { args in
        // Extract args, call input.pinchZoom(), return MCPToolResult
    }
))
```

### Step 5: Update Test Doubles

Add stub methods in:

- `Tests/MCPServerTests/TestDoubles.swift` — add to `StubInput`

### Step 6: Write Tests

Add tests in `Tests/MCPServerTests/` for tool handler logic and `Tests/HelperLibTests/` for shared utilities.

### Step 7: Update Documentation

- Add the tool to `docs/tools.md`

## Test Architecture

### Test Targets

| Target | Framework | Files | Purpose |
|--------|-----------|-------|---------|
| `MCPServerTests` | XCTest | 94 | Server routing, tool handlers, exploration algorithms, component detection, graph algorithms |
| `HelperLibTests` | Swift Testing | 11 | Key mapping, permissions, protocol types, OCR coordinates, layout translation |
| `TestRunnerTests` | Swift Testing | 14 | Skill parsing, step execution, element matching, event classification, reporters |
| `IntegrationTests` | XCTest | 15 | Full workflows with FakeMirroring app (requires running FakeMirroring, skipped in CI unit tests) |

### Dependency Injection

All test targets use protocol-based DI. Real implementations are swapped with stubs:

**MCPServerTests stubs** (`TestDoubles.swift`):
- `StubBridge` — configurable window info, state, orientation
- `StubInput` — configurable results for tap/swipe/type/etc.
- `StubCapture` — returns configured base64 screenshot data
- `StubRecorder` — returns configured recording start/stop results
- `StubDescriber` — returns configured OCR describe results

## Environment Variable Overrides

All timing and numeric constants can be overridden via environment variables. The variable name follows the pattern `MIRROIR_<CONSTANT_NAME>`.

### Cursor & Input Settling

| Variable | Default | Description |
|----------|---------|-------------|
| `MIRROIR_CURSOR_SETTLE_US` | 10,000 (10ms) | Wait after cursor warp for macOS to register position |
| `MIRROIR_CLICK_HOLD_US` | 80,000 (80ms) | Button hold duration for single tap |
| `MIRROIR_DOUBLE_TAP_HOLD_US` | 40,000 (40ms) | Button hold per tap in double-tap |
| `MIRROIR_DOUBLE_TAP_GAP_US` | 50,000 (50ms) | Gap between taps in double-tap |
| `MIRROIR_DRAG_MODE_HOLD_US` | 150,000 (150ms) | Hold before drag movement for iOS drag recognition |
| `MIRROIR_FOCUS_SETTLE_US` | 200,000 (200ms) | Wait after keyboard focus click |
| `MIRROIR_KEYSTROKE_DELAY_US` | 15,000 (15ms) | Delay between keystrokes |
| `MIRROIR_DEAD_KEY_DELAY_US` | 30,000 (30ms) | Delay in dead-key compose sequences (accented characters) |

### App Switching & Navigation

| Variable | Default | Description |
|----------|---------|-------------|
| `MIRROIR_SPACE_SWITCH_SETTLE_US` | 300,000 (300ms) | Wait after macOS Space switch |
| `MIRROIR_SPOTLIGHT_APPEARANCE_US` | 800,000 (800ms) | Wait for Spotlight to appear |
| `MIRROIR_SEARCH_RESULTS_POPULATE_US` | 1,000,000 (1.0s) | Wait for search results |
| `MIRROIR_SAFARI_LOAD_US` | 1,500,000 (1.5s) | Wait for Safari page load |
| `MIRROIR_ADDRESS_BAR_ACTIVATE_US` | 500,000 (500ms) | Wait for address bar activation |
| `MIRROIR_PRE_RETURN_US` | 300,000 (300ms) | Wait before pressing Return |

### Process & System Polling

| Variable | Default | Description |
|----------|---------|-------------|
| `MIRROIR_PROCESS_POLL_US` | 50,000 (50ms) | Polling interval for process completion |
| `MIRROIR_EARLY_FAILURE_DETECT_US` | 500,000 (500ms) | Wait before checking for early process failure |
| `MIRROIR_RESUME_FROM_PAUSED_US` | 2,000,000 (2.0s) | Wait after resuming paused mirroring |

### Non-Timing Constants

| Variable | Default | Description |
|----------|---------|-------------|
| `MIRROIR_DRAG_INTERPOLATION_STEPS` | 60 | Number of movement steps in drag |
| `MIRROIR_SWIPE_INTERPOLATION_STEPS` | 20 | Number of scroll steps in swipe |
| `MIRROIR_SCROLL_PIXEL_SCALE` | 8.0 | Divisor converting pixels to scroll ticks |

### App Identity

| Variable | Default | Description |
|----------|---------|-------------|
| `MIRROIR_BUNDLE_ID` | `com.apple.ScreenContinuity` | Target app bundle ID for process discovery |
| `MIRROIR_PROCESS_NAME` | `iPhone Mirroring` | Target app display name for messages |

### Keyboard Layout

| Variable | Default | Description |
|----------|---------|-------------|
| `IPHONE_KEYBOARD_LAYOUT` | *(not set)* | Opt-in non-US keyboard layout for character translation (e.g., `Canadian-CSA` or `com.apple.keylayout.Canadian-CSA`). When unset, US QWERTY keycodes are sent. |

## FakeMirroring

FakeMirroring is a real macOS app that stands in for iPhone Mirroring during testing. It renders OCR-detectable text at known positions, responds to CGEvent taps, and supports scrolling — everything the real mirroring window does, without needing a physical iPhone.

### Build & Run

```bash
swift build -c release --product FakeMirroring
./scripts/package-fake-app.sh
open .build/release/FakeMirroring.app
```

The app window is 410x898pt (matching iPhone screen dimensions) and floats above other windows so CGEvent taps always land on it.

### Simulated Apps (AppPacks)

FakeMirroring is an **APP.md-driven multi-app simulator**. Each simulated app is an
`AppPack` — a `SimulatorSpec` parsed from the `## Simulator …` sections of an APP.md
file in the configured skills directory. At startup `AppRegistry.loadPacks(from:)`
loads every APP.md that declares a simulator block; apps without one are skipped
(guidance-only). `AppRegistry` brokers Spotlight launches and force-quits between
packs, and the App Switcher overlay renders one card per running pack.

A `SimulatorSpec` declares an `appName`, `spotlightName`, `icon`, a `rootScreenID`,
a map of `SimulatorScreen`s, and a list of `SimulatorObstacle`s (modal dialogs). Each
screen has a `title`, optional `backTo` target, `hasTabBar` flag, and a list of
`SimulatorElement`s: `row`, `button`, `text`, `tab`, `textField`, `slider`, and
`placeholder` (media rectangle). Tappable elements (`row`/`button`/`tab`) carry a
`leadsTo` screen ID, which is how the BFS explorer discovers new screens during
integration tests.

The legacy menu bar **Scenario menu** is still built — one item per loaded pack — so
existing integration tests can switch the foreground app via
`bridge.triggerMenuAction(menu: "Scenario", item: "Settings")`. The menu is a
test-only convenience; it maps each menu title to a registered pack. FakeMirroring
defaults to the Settings pack on launch so tests start on a known screen.

### Adding a Simulated App or Screen

There is no `FakeScenario` enum to edit — apps live entirely in APP.md:

1. Add (or edit) an APP.md in the skills repo (`patterns/apps/<app>/APP.md`) with a
   `## Simulator` section declaring `root_screen` and metadata, plus one
   `## Simulator Screen <id>` section per screen and `## Simulator Obstacle <id>` per
   modal. Bullet syntax is `- key: value` for properties and `- element <kind>: …`
   for screen elements (see `SimulatorSpecParser` unit tests for examples).
2. Reload — FakeMirroring picks up the new pack on next launch via
   `AppRegistry.loadPacks(from:)`. No Swift changes are needed for a new app or screen.
3. `SceneRenderer` turns the active `SimulatorScreen` (plus any triggered obstacle)
   into the `ScenarioData` the existing AppKit draw pipeline already knows how to render.

### Navigation & Obstacles

Tap routing is data-driven: tapping a `row`/`button`/`tab` navigates to its `leadsTo`
screen, and the back chevron returns to the screen's `backTo` target. A tap on a
non-interactive element (`text`, `placeholder`) is a dead tap (no screen change).
Obstacles are modal dialogs declared per app; their trigger (`SimulatorObstacleTrigger`)
decides when they interrupt exploration. Obstacle rules are honored by the BFS explorer.

### Input Handling

FakeMirroring handles: mouse clicks (tap), `scrollWheel` (swipe/scroll), `mouseDragged` (drag), long press (0.4s threshold), double tap (0.3s gap), and `keyDown` (text field typing). Hit regions are computed from rendered element positions. The `AlwaysAcceptingWindow` subclass accepts mouse events even when not the key window, so CGEvent-posted taps work during integration tests.

## Integration Tests

Integration tests in `Tests/IntegrationTests/` run real OCR against FakeMirroring's rendered text. They exercise the full pipeline: OCR → coordinate mapping → CGEvent tap → verify screen change.

### Running

```bash
# Build and launch FakeMirroring first
swift build -c release --product FakeMirroring
./scripts/package-fake-app.sh
open .build/release/FakeMirroring.app

# Run integration tests (FakeMirroring must be visible)
swift test --filter IntegrationTests

# Run a single test
swift test --filter BFSExplorationIntegrationTests/testMultiViewportExploration
```

Integration tests are **skipped in CI** (`swift test --skip IntegrationTests`) because they require a visible macOS window and CGEvent access. They run locally before merging.

### Test Pattern

Every integration test follows this pattern:

```swift
override func setUpWithError() throws {
    try IntegrationTestHelper.ensureFakeMirroringRunning()
    bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
    guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
        throw IntegrationTestError.windowNotCapturable
    }
    describer = ScreenDescriber(bridge: bridge, capture: ScreenCapture(bridge: bridge))
    input = InputSimulation(bridge: bridge)

    _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
    usleep(500_000)
}

override func tearDown() {
    // Restore default scenario for other tests
    _ = bridge?.triggerMenuAction(menu: "Scenario", item: "Settings")
    usleep(500_000)
}
```

Tests create `ScreenDescriber`, `InputSimulation`, and `ExplorationSession` directly — no MCP transport needed.

### Testing BFS Exploration

Two approaches, use the right one:

| Approach | When to use | Speed |
|----------|-------------|-------|
| **Unit tests** (`MockExplorerDescriber`) | Testing scroll logic, plan building, action counters, specific code paths | Fast (~2s) |
| **Integration tests** (FakeMirroring) | Testing full exploration loop with real OCR, tap routing, backtracking | Slow (~2min) |

Unit test mocks return a pre-defined sequence of screens. Integration tests use real OCR output that varies slightly between runs. Use `seed: 42` for deterministic tap ordering in integration tests.

## Component Skills

Component definitions are `.md` files that describe iOS UI patterns (table rows, summary cards, modal sheets). The BFS explorer matches OCR elements against these definitions to decide what to tap.

Definitions live in the sibling [mirroir-skills](https://github.com/jfarcand/mirroir-skills) repo at `patterns/elements/`. They're loaded at runtime from `<cwd>/.mirroir-mcp/skills/patterns/elements/`, `~/.mirroir-mcp/skills/patterns/elements/`, or `../mirroir-skills/patterns/elements/`, with the older `components/ios/` paths kept as a fallback. (`.mirroir-mcp/` is the Swift MCP home directory; do not confuse it with `.mirroir/`, the runner's consumer dotfile.)

Each definition has: Match Rules (zone, element count, chevron/numeric patterns), Interaction (click target, expected result), Exploration (explorable flag, role, priority), and Grouping (row absorption).

Test a definition against the current live screen with `calibrate_component`. See [Component Detection](docs/components.md) for the full format.

## Code Conventions

### File Headers

Every Swift file must have:
1. Apache 2.0 license header (enforced by pre-commit hook)
2. Two-line ABOUTME comment explaining the file's purpose:

```swift
// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Brief description of what this file does.
// ABOUTME: Second line with additional context.
```

### Error Handling

- Use `throws` / `try` / `catch` for error propagation
- Use `Result<T, Error>` for async or callback-based error handling
- Custom error types must conform to `Error` protocol
- No `try!` except for static data known valid at compile time
- No `fatalError()` except in unreachable code paths

### Concurrency

- All shared types must conform to `Sendable`
- Use a lock for protecting mutable shared state — `OSAllocatedUnfairLock` (e.g. `MCPServer`, `TargetRegistry`, `ScreenRecorder`) or `NSLock` (e.g. `ExplorationSession` and other session accumulators)
- Protocol abstractions enable safe dependency injection

### Logging

- All logging goes to **stderr** (stdout is reserved for JSON-RPC)
- Use `DebugLog.log()` for debug-only messages
- Use `DebugLog.persist()` for messages that always appear in the log file
- Never log access tokens, API keys, passwords, or secrets

### Git Workflow

- **Features:** Create a branch (`feature/my-feature`), squash merge locally to main
- **Bug fixes:** Commit directly to main
- **Never create Pull Requests** — all merges happen locally
- **Commit messages must use conventional commit format:** `type(scope): description`
  - Types: `feat`, `fix`, `chore`, `docs`, `test`, `refactor`, `ci`, `style`, `perf`, `build`, `revert`
  - Scope is optional. Multi-scope with `|` is permitted: `fix(module|context): description`
  - Examples: `feat: add check_health tool`, `fix(skills): handle YAML block scalars`
  - The `commit-msg` hook in `.githooks/` enforces this — non-conventional commits are rejected
- No AI assistant references in commit messages
