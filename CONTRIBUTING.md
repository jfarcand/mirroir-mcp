# Contributing to iPhone Mirroir MCP

Thank you for your interest in contributing! By submitting a contribution, you agree to the [Contributor License Agreement](CLA.md). Your Git commit metadata (name and email) serves as your electronic signature.

## Getting Started

1. Fork the repository and clone your fork
2. Run the [installer](mirroir.sh) to set up dependencies (DriverKit virtual HID, helper daemon)
3. Read this guide and the [Architecture](docs/architecture.md) doc to understand the system
4. Create a feature branch for your work

## Project Structure

```
iphone-mirroir-mcp/
├── Sources/
│   ├── iphone-mirroir-mcp/     # MCP server + CLI subcommands (user process)
│   │   ├── iphone_mirroir_mcp.swift  # Entry point (dispatches test/record subcommands)
│   │   ├── MCPServer.swift           # JSON-RPC 2.0 dispatch
│   │   ├── ToolHandlers.swift        # Tool registration orchestrator
│   │   ├── ScreenTools.swift         # screenshot, describe_screen, recording
│   │   ├── InputTools.swift          # tap, swipe, drag, type, press_key, etc.
│   │   ├── NavigationTools.swift     # launch_app, open_url, home, spotlight
│   │   ├── ScrollToTools.swift       # scroll_to — scroll until element visible
│   │   ├── AppManagementTools.swift  # reset_app — force-quit via App Switcher
│   │   ├── MeasureTools.swift        # measure — time screen transitions
│   │   ├── NetworkTools.swift        # set_network — toggle airplane/wifi/cellular
│   │   ├── InfoTools.swift           # status, get_orientation, check_health
│   │   ├── ScenarioTools.swift       # list_scenarios, get_scenario
│   │   ├── Protocols.swift           # DI protocol abstractions
│   │   ├── MirroringBridge.swift     # AX window discovery + menu actions
│   │   ├── InputSimulation.swift     # Coordinate mapping + focus management
│   │   ├── ScreenCapture.swift       # screencapture -l wrapper
│   │   ├── ScreenRecorder.swift      # Video recording state machine
│   │   ├── ScreenDescriber.swift     # Vision OCR pipeline
│   │   ├── HelperClient.swift        # Unix socket client to helper daemon
│   │   ├── DebugLog.swift            # Debug logging to stderr + file
│   │   ├── TestRunner.swift          # `mirroir test` orchestrator
│   │   ├── ScenarioParser.swift      # YAML → structured ScenarioStep list
│   │   ├── StepExecutor.swift        # Runs steps against real subsystems
│   │   ├── ElementMatcher.swift      # Fuzzy OCR text matching (exact/case/substring)
│   │   ├── ConsoleReporter.swift     # Terminal output formatting for test runner
│   │   ├── JUnitReporter.swift       # JUnit XML generation for CI
│   │   ├── EventRecorder.swift       # `mirroir record` — CGEvent tap monitoring
│   │   ├── YAMLGenerator.swift       # Recorded events → scenario YAML
│   │   └── RecordCommand.swift       # `mirroir record` CLI entry point
│   │
│   ├── iphone-mirroir-helper/  # Root LaunchDaemon
│   │   ├── HelperDaemon.swift        # Entry point (root verification, signal handlers)
│   │   ├── CommandServer.swift       # Unix stream socket listener
│   │   ├── CommandHandlers.swift     # 10 action handlers (click, type, swipe, etc.)
│   │   ├── CursorSync.swift          # Save/warp/nudge/restore cursor pattern
│   │   ├── KarabinerClient.swift     # Karabiner DriverKit virtual HID protocol
│   │   └── KarabinerProviding.swift  # Protocol abstraction for Karabiner client
│   │
│   └── HelperLib/              # Shared library (linked into both + tests)
│       ├── MCPProtocol.swift         # JSON-RPC + MCP types (JSONValue, tool defs)
│       ├── PermissionPolicy.swift    # Fail-closed permission engine
│       ├── HIDKeyMap.swift           # Character → USB HID keycode mapping
│       ├── HIDSpecialKeyMap.swift    # Named key → HID keycode mapping
│       ├── LayoutMapper.swift        # Non-US keyboard layout translation
│       ├── PackedStructs.swift       # Binary HID report structs
│       ├── TimingConstants.swift     # Default timing values
│       ├── EnvConfig.swift           # Environment variable overrides
│       ├── TapPointCalculator.swift  # Smart OCR tap coordinate offset
│       ├── GridOverlay.swift         # Coordinate grid overlay on screenshots
│       ├── ContentBoundsDetector.swift # Detects iPhone content bounds in screenshots
│       ├── AppleScriptKeyMap.swift   # macOS virtual key codes
│       └── ProcessExtensions.swift   # Timeout-aware Process.wait
│
├── Tests/
│   ├── MCPServerTests/         # XCTest — server routing + tool handlers
│   ├── HelperDaemonTests/      # XCTest — command dispatch + Karabiner wire
│   ├── HelperLibTests/         # Swift Testing — shared library utilities
│   ├── TestRunnerTests/        # Swift Testing — test runner, recorder, scenario parser
│   ├── IntegrationTests/       # XCTest — FakeMirroring integration (requires running app)
│   └── Fixtures/               # Test scenario YAML files
│
├── scripts/                    # Install/uninstall helper scripts
├── Resources/                  # LaunchDaemon plist
└── docs/                       # Documentation
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
swift test
```

**Tier 3 — Full Validation** (before merge):
```bash
swift build -c release
swift test
```

### Pre-commit Hooks

The project uses Git hooks (`.githooks/pre-commit`) that enforce:

1. **Apache 2.0 license headers** on all Swift files (except `Package.swift`)
2. **ABOUTME headers** — every non-test Swift file must have a 2-line ABOUTME comment
3. **No suspicious files** — blocks `.bak`, `.orig`, `.tmp`, `.swp` files
4. **Swift build** — compilation must succeed
5. **MCP compliance** — validates protocol version, server name, and tool schema (when MCP files change)

Set up the hooks:
```bash
git config core.hooksPath .githooks
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

If the tool needs a protocol abstraction (most input tools do), add a method to the relevant protocol in `Sources/iphone-mirroir-mcp/Protocols.swift`:

```swift
protocol InputProviding: Sendable {
    // ... existing methods ...
    func pinchZoom(x: Double, y: Double, scale: Double) -> String?
}
```

### Step 3: Implement the Method

Add the implementation to the real class (e.g., `InputSimulation`):

```swift
func pinchZoom(x: Double, y: Double, scale: Double) -> String? {
    // Coordinate mapping, helper client call, etc.
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

### Step 5: Helper Support (if needed)

If the tool requires HID input through the helper daemon:

1. Add a case to the `processCommand` switch in `CommandHandlers.swift`
2. Implement the handler method using `CursorSync` pattern
3. Add the corresponding method to `HelperClient.swift`

### Step 6: Update Test Doubles

Add stub methods in both test targets:

- `Tests/MCPServerTests/TestDoubles.swift` — add to `StubInput`
- `Tests/HelperDaemonTests/TestDoubles.swift` — add to `StubKarabiner` (if helper-side)

### Step 7: Write Tests

Add tests in the appropriate test target:

- Tool handler tests → `Tests/MCPServerTests/`
- Helper command tests → `Tests/HelperDaemonTests/`
- Shared utility tests → `Tests/HelperLibTests/`

### Step 8: Update Documentation

- Add the tool to `docs/tools.md`
- Update `docs/architecture.md` if the tool introduces a new input path

## How to Add a New Helper Command

To add a new action handled by the root helper daemon:

### Step 1: Add to processCommand

In `Sources/iphone-mirroir-helper/CommandHandlers.swift`, add a case to the action switch:

```swift
case "my_action":
    return handleMyAction(json)
```

### Step 2: Implement the Handler

Write a handler method following the `CursorSync` pattern for touch operations:

```swift
private func handleMyAction(_ json: [String: Any]) -> Data {
    guard let x = doubleParam(json, "x"),
          let y = doubleParam(json, "y") else {
        return makeErrorResponse("Missing x/y")
    }
    CursorSync.withCursorSynced(at: CGPoint(x: x, y: y), karabiner: karabiner) {
        // Karabiner HID operations
    }
    return makeOkResponse()
}
```

### Step 3: Add Client Method

In `Sources/iphone-mirroir-mcp/HelperClient.swift`, add a convenience method:

```swift
func myAction(x: Double, y: Double) -> [String: Any]? {
    send(["action": "my_action", "x": x, "y": y])
}
```

### Step 4: Write Tests

Add tests in `Tests/HelperDaemonTests/` using `StubKarabiner` to verify HID operations.

## Test Architecture

### Three Test Targets

| Target | Framework | Tests | Purpose |
|--------|-----------|-------|---------|
| `MCPServerTests` | XCTest | Server routing, tool handler logic | Verifies JSON-RPC dispatch, tool parameter validation, permission enforcement |
| `HelperDaemonTests` | XCTest | Command dispatch, Karabiner wire protocol | Verifies action handlers, HID report generation, parameter validation |
| `HelperLibTests` | Swift Testing | Shared utilities | Verifies key mapping, permissions, protocol types, OCR coordinates, layout translation |

### Dependency Injection

All test targets use protocol-based DI. Real implementations are swapped with stubs:

**MCPServerTests stubs** (`TestDoubles.swift`):
- `StubBridge` — configurable window info, state, orientation
- `StubInput` — configurable results for tap/swipe/type/etc.
- `StubCapture` — returns configured base64 screenshot data
- `StubRecorder` — returns configured recording start/stop results
- `StubDescriber` — returns configured OCR describe results

**HelperDaemonTests stubs** (`TestDoubles.swift`):
- `StubKarabiner` — records all calls for verification:
  - `postedPointingReports` — array of `PointingInput` sent
  - `postedKeyboardReports` — array of `KeyboardInput` sent
  - `typedKeys` — array of `(keycode, modifiers)` tuples
  - `movedDeltas` — array of `(dx, dy)` tuples
  - `clickedButtons` — array of button values
  - `releasedCount` — counter for `releaseButtons()` calls

## Environment Variable Overrides

All timing and numeric constants can be overridden via environment variables. The variable name follows the pattern `IPHONE_MIRROIR_<CONSTANT_NAME>`.

### Cursor & Input Settling

| Variable | Default | Description |
|----------|---------|-------------|
| `IPHONE_MIRROIR_CURSOR_SETTLE_US` | 10,000 (10ms) | Wait after cursor warp for macOS to register position |
| `IPHONE_MIRROIR_NUDGE_SETTLE_US` | 5,000 (5ms) | Wait between nudge movements |
| `IPHONE_MIRROIR_CLICK_HOLD_US` | 80,000 (80ms) | Button hold duration for single tap |
| `IPHONE_MIRROIR_DOUBLE_TAP_HOLD_US` | 40,000 (40ms) | Button hold per tap in double-tap |
| `IPHONE_MIRROIR_DOUBLE_TAP_GAP_US` | 50,000 (50ms) | Gap between taps in double-tap |
| `IPHONE_MIRROIR_DRAG_MODE_HOLD_US` | 150,000 (150ms) | Hold before drag movement for iOS drag recognition |
| `IPHONE_MIRROIR_FOCUS_SETTLE_US` | 200,000 (200ms) | Wait after keyboard focus click |
| `IPHONE_MIRROIR_KEYSTROKE_DELAY_US` | 15,000 (15ms) | Delay between keystrokes |

### App Switching & Navigation

| Variable | Default | Description |
|----------|---------|-------------|
| `IPHONE_MIRROIR_SPACE_SWITCH_SETTLE_US` | 300,000 (300ms) | Wait after macOS Space switch |
| `IPHONE_MIRROIR_SPOTLIGHT_APPEARANCE_US` | 800,000 (800ms) | Wait for Spotlight to appear |
| `IPHONE_MIRROIR_SEARCH_RESULTS_POPULATE_US` | 1,000,000 (1.0s) | Wait for search results |
| `IPHONE_MIRROIR_SAFARI_LOAD_US` | 1,500,000 (1.5s) | Wait for Safari page load |
| `IPHONE_MIRROIR_ADDRESS_BAR_ACTIVATE_US` | 500,000 (500ms) | Wait for address bar activation |
| `IPHONE_MIRROIR_PRE_RETURN_US` | 300,000 (300ms) | Wait before pressing Return |

### Process & System Polling

| Variable | Default | Description |
|----------|---------|-------------|
| `IPHONE_MIRROIR_PROCESS_POLL_US` | 50,000 (50ms) | Polling interval for process completion |
| `IPHONE_MIRROIR_EARLY_FAILURE_DETECT_US` | 500,000 (500ms) | Wait before checking for early process failure |
| `IPHONE_MIRROIR_RESUME_FROM_PAUSED_US` | 2,000,000 (2.0s) | Wait after resuming paused mirroring |
| `IPHONE_MIRROIR_POST_HEARTBEAT_SETTLE_US` | 100,000 (100ms) | Wait after initial Karabiner heartbeat |

### Karabiner HID

| Variable | Default | Description |
|----------|---------|-------------|
| `IPHONE_MIRROIR_KEY_HOLD_US` | 20,000 (20ms) | Key hold duration for virtual keyboard |
| `IPHONE_MIRROIR_DEAD_KEY_DELAY_US` | 30,000 (30ms) | Delay in dead-key compose sequences (accented characters) |
| `IPHONE_MIRROIR_RECV_TIMEOUT_US` | 200,000 (200ms) | Socket receive timeout |

### Non-Timing Constants

| Variable | Default | Description |
|----------|---------|-------------|
| `IPHONE_MIRROIR_DRAG_INTERPOLATION_STEPS` | 60 | Number of movement steps in drag |
| `IPHONE_MIRROIR_SWIPE_INTERPOLATION_STEPS` | 20 | Number of scroll steps in swipe |
| `IPHONE_MIRROIR_SCROLL_PIXEL_SCALE` | 8.0 | Divisor converting pixels to scroll ticks |
| `IPHONE_MIRROIR_HID_TYPING_CHUNK_SIZE` | 15 | Characters per typing chunk |
| `IPHONE_MIRROIR_STAFF_GROUP_ID` | 20 | Unix group ID for socket permissions |

### App Identity

| Variable | Default | Description |
|----------|---------|-------------|
| `IPHONE_MIRROIR_BUNDLE_ID` | `com.apple.ScreenContinuity` | Target app bundle ID for process discovery |
| `IPHONE_MIRROIR_PROCESS_NAME` | `iPhone Mirroring` | Target app display name for messages |

### Keyboard Layout

| Variable | Default | Description |
|----------|---------|-------------|
| `IPHONE_KEYBOARD_LAYOUT` | *(not set)* | Opt-in non-US keyboard layout for character translation (e.g., `Canadian-CSA` or `com.apple.keylayout.Canadian-CSA`). When unset, US QWERTY keycodes are sent. |

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
- Use `OSAllocatedUnfairLock` for protecting mutable state
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
- Commit messages: 1-2 lines, no AI assistant references
