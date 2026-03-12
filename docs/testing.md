# Testing

How iPhone Mirroir MCP achieves reliable CI testing without a physical iPhone.

## The Problem

iPhone Mirroir MCP controls a real iPhone through macOS iPhone Mirroring — an app that streams the iPhone display and forwards touch/keyboard input over AirPlay + Bluetooth LE. Every core feature (screenshots, OCR, tap, swipe, menu traversal) depends on a live mirroring session with a physical device.

CI runners have no iPhones. Testing the install-and-run path without hardware requires a different approach.

## The Solution: FakeMirroring

`FakeMirroring` is a lightweight macOS app that stands in for iPhone Mirroring during CI. It provides the same macOS API surface the MCP server depends on:

| API Surface | iPhone Mirroring | FakeMirroring |
|-------------|-----------------|---------------|
| `NSWorkspace.runningApplications` (process discovery) | `com.apple.ScreenContinuity` | `com.jfarcand.FakeMirroring` |
| `AXUIElement` main window | 410×898pt mirrored display | 410×898pt NSWindow |
| `CGWindowListCopyWindowInfo` (window ID) | Continuity compositor window | Standard NSWindow |
| `screencapture -l <windowID>` | iPhone screen pixels | Dark background with text labels |
| Vision OCR (`VNRecognizeTextRequest`) | Real iOS UI text | Rendered labels: "Settings", "Safari", "9:41", etc. |
| AX menu bar traversal | View > Home Screen, Spotlight, App Switcher | View > Home Screen, Spotlight, App Switcher |

FakeMirroring is **not a mock** — it is a real macOS app exercising real macOS APIs. The MCP server calls the same `AXUIElement`, `CGWindowList`, `screencapture`, and Vision APIs it would use against iPhone Mirroring. The only difference is which process those APIs target.

### How Targeting Works

The MCP server discovers the mirroring app by bundle ID and process name. Two environment variables control this:

```
MIRROIR_BUNDLE_ID=com.jfarcand.FakeMirroring
MIRROIR_PROCESS_NAME=FakeMirroring
```

When unset, they default to `com.apple.ScreenContinuity` and `iPhone Mirroring` — the real app. This is the same `EnvConfig` system used for all runtime configuration (timing constants, keyboard parameters, etc.), so there is no test-only code path in production.

**Ref:** `Sources/HelperLib/EnvConfig.swift`

### What FakeMirroring Renders

```
┌──────────────────────────────────────────┐
│                 FakeMirroring            │  ← title bar
├──────────────────────────────────────────┤
│                                          │
│                  9:41                    │  ← status bar text
│                                          │
│                                          │
│  Settings    Safari    Photos    Camera  │  ← app icon labels (y=300)
│                                          │
│                                          │
│  Messages    Mail      Clock     Maps   │  ← app icon labels (y=500)
│                                          │
│                                          │
│                                          │
│              (dark background)           │
│                                          │
└──────────────────────────────────────────┘
  410pt × 898pt, white text on dark bg
```

Labels are rendered at 18pt medium weight on a dark background — high enough contrast for reliable Vision OCR detection across macOS versions.

**Ref:** `Sources/FakeMirroring/main.swift`

### App Bundle Packaging

FakeMirroring is built as a Swift executable, then packaged into a `.app` bundle with a proper `Info.plist` so macOS registers its bundle ID:

```bash
swift build -c release --product FakeMirroring
./scripts/package-fake-app.sh
open .build/release/FakeMirroring.app
```

The packaging script creates the standard `Contents/MacOS/` + `Contents/Info.plist` structure and verifies the bundle ID matches `com.jfarcand.FakeMirroring`.

**Ref:** `scripts/package-fake-app.sh`, `Resources/FakeMirroring/Info.plist`

## Test Tiers

### Unit Tests (`swift test --skip IntegrationTests`)

Run without any external dependencies. Three test targets:

| Target | Tests | What It Validates |
|--------|-------|-------------------|
| `HelperLibTests` | Key maps, layout mapper, permission policy, tap point calculator, grid overlay, MCP protocol types | Shared library logic |
| `MCPServerTests` | JSON-RPC dispatch, tool registration, permission enforcement, protocol negotiation | MCP server behavior using protocol-based test doubles |
| `TestRunnerTests` | Skill parsing, step execution, element matching, YAML generation, event classification, JUnit/console reporters | Test runner (`mirroir test`) and recorder (`mirroir record`) |

Unit tests use **protocol-based dependency injection** — protocols (`WindowBridging`/`MenuActionCapable`, `InputProviding`, `ScreenCapturing`, `ScreenRecording`, `ScreenDescribing`, `ExplorationStrategy`, `ComponentClassifying`) have stub implementations for test isolation. See `Tests/MCPServerTests/TestDoubles.swift`.

### Integration Tests (`swift test --filter IntegrationTests`)

Require FakeMirroring to be running. Exercise real macOS APIs:

| Test | What It Validates |
|------|-------------------|
| `testFindProcess` | `NSWorkspace.runningApplications` finds FakeMirroring by bundle ID |
| `testGetWindowInfo` | `AXUIElement` retrieves window position, size (410×898pt), and `CGWindowID` |
| `testGetState` | AX child-count heuristic correctly reports `.connected` for empty content view |
| `testGetOrientation` | Window dimensions → `.portrait` orientation detection |
| `testTriggerMenuAction` | AX menu bar traversal: View > Spotlight succeeds |
| `testCaptureBase64` | `screencapture -l <windowID>` produces valid PNG (base64 prefix check) |
| `testDescribeScreen` | Vision OCR detects "settings", "safari", "9:41" in the captured screenshot |
| `testOCRCoordinateAccuracy` | All OCR tap coordinates fall within window bounds with ≥0.5 confidence |

**Ref:** `Tests/IntegrationTests/FakeMirroringIntegrationTests.swift`

### End-to-End MCP Tests (CI workflow)

Exercise the **installed binary** via JSON-RPC over stdio:

```bash
# MCP initialize — verifies server starts and responds
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | .build/release/mirroir-mcp 2>/dev/null \
  | python3 -c "..." # assert serverInfo.name == 'mirroir-mcp'

# MCP tools/call screenshot — verifies full pipeline (binary → AX → screencapture → base64)
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n...' \
  | .build/release/mirroir-mcp --dangerously-skip-permissions 2>/dev/null \
  | python3 -c "..." # assert response contains image content block
```

These tests prove the installed binary (from any install path) can discover FakeMirroring, capture its window, and return a valid screenshot through the MCP protocol.

## CI Workflow: `installers.yml`

Three parallel jobs test each installation method end-to-end on `macos-15` runners:

### Job 1: `source-install` — mirroir.sh

Tests the one-line installer script that users run after cloning.

```
./mirroir.sh → build FakeMirroring → launch →
  swift test --filter IntegrationTests (8 tests) →
  MCP initialize → MCP tools/call screenshot
```

### Job 2: `homebrew-install` — Local Homebrew formula

Tests the Homebrew installation path using a local tap.

```
git archive tarball → brew tap-new local/test →
  generate formula with file:// URL → brew install local/test/mirroir-mcp →
  build FakeMirroring → launch →
  swift test --filter IntegrationTests (8 tests) →
  MCP initialize → MCP tools/call screenshot
```

### Job 3: `npx-install` — NPM package

Tests the npm/npx installation path.

```
swift build → stage binary into npm/bin/ →
  build FakeMirroring → launch →
  swift test --filter IntegrationTests (8 tests) →
  MCP initialize → MCP tools/call screenshot
```

### What Each Job Proves

| Checkpoint | source-install | homebrew-install | npx-install |
|-----------|---------------|-----------------|-------------|
| Binary builds from source | `mirroir.sh` | Homebrew formula `swift build` | Direct `swift build` |
| Binary location correct | `.build/release/` | `/opt/homebrew/bin/` | `npm/bin/` |
| Process discovery works | Integration test | Integration test | Integration test |
| AX window access works | Integration test | Integration test | Integration test |
| Screenshot capture works | Integration test + MCP | Integration test + MCP | Integration test + MCP |
| OCR pipeline works | Integration test | Integration test | Integration test |
| MCP protocol correct | MCP initialize + screenshot | MCP initialize + screenshot | MCP initialize + screenshot |

## Running Locally

To run the same tests CI runs:

```bash
# 1. Build and launch FakeMirroring
swift build -c release --product FakeMirroring
./scripts/package-fake-app.sh
open .build/release/FakeMirroring.app

# 2. Run integration tests
MIRROIR_BUNDLE_ID=com.jfarcand.FakeMirroring \
MIRROIR_PROCESS_NAME=FakeMirroring \
swift test --filter IntegrationTests
```

## Design Rationale

**Why not XCUITest?** XCUITest is designed for testing your own app's UI. iPhone Mirroir MCP tests the interaction between a CLI tool and a third-party window via system-level APIs (Accessibility, CGWindow, Vision). XCUITest cannot target other processes.

**Why not mock the APIs?** Mocking `AXUIElement`, `CGWindowListCopyWindowInfo`, and `VNRecognizeTextRequest` would test the mock, not the integration. FakeMirroring exercises the real API call chain — if Apple changes how `AXUIElementCopyAttributeValue` works in a new macOS version, the tests catch it.

**Why environment variables instead of a protocol?** The target app identity is a process-level concern, not a per-call concern. Every subsystem (`MirroringBridge`, `ScreenCapture`, `ScreenDescriber`) needs to agree on which app to target. Environment variables set once at process startup are simpler than threading a configuration object through every initializer.
