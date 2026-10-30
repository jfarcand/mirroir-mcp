// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Integration tests that exercise real macOS APIs against the FakeMirroring app.
// ABOUTME: Validates MirroringBridge, ScreenCapture, and ScreenDescriber using a live window.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Integration tests that require the FakeMirroring app to be running.
/// Auto-detects FakeMirroring and configures the bridge — no env vars needed locally.
///
/// Run with: `swift test --filter IntegrationTests`
///
/// FakeMirroring must be running:
///   `swift build -c release --product FakeMirroring && ./scripts/package-fake-app.sh`
///   `open .build/release/FakeMirroring.app`
final class FakeMirroringIntegrationTests: XCTestCase {

    private var bridge: MirroringBridge!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Auto-launch FakeMirroring if not already running — no env vars needed.
        try IntegrationTestHelper.ensureFakeMirroringRunning()

        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)

        // Ensure window is capturable — prior test classes may have exhausted screencapture
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            XCTFail("FakeMirroring window not capturable after retries")
            return
        }

        // Reset to a clean Settings cold launch so OCR/AX assertions don't
        // see leftover obstacle dialogs or non-root screens from prior tests.
        IntegrationTestHelper.resetScenario(bridge: bridge, to: "Settings")
    }

    // MARK: - MirroringBridge Tests

    func testFindProcess() {
        let process = bridge.findProcess()
        XCTAssertNotNil(process, "Should find FakeMirroring process by bundle ID")
        XCTAssertEqual(process?.bundleIdentifier, IntegrationTestHelper.fakeBundleID)
    }

    func testGetWindowInfo() {
        let info = bridge.getWindowInfo()
        XCTAssertNotNil(info, "Should retrieve window info via AX APIs")

        guard let info = info else { return }

        XCTAssertNotEqual(info.windowID, 0, "Window ID should be non-zero")
        XCTAssertEqual(info.size.width, 410, accuracy: 2, "Window width should be ~410pt")
        // Window height includes the title bar (~30pt), so content height 898 + title bar
        XCTAssertGreaterThan(info.size.height, 890, "Window height should be >= 890pt (content + title bar)")
        XCTAssertGreaterThan(info.pid, 0, "PID should be positive")
    }

    func testGetState() {
        let state = bridge.getState()
        // FakeScreenView has no subviews, so the AX tree should show:
        // Window > contentView (hosting view) > no children = .connected
        XCTAssertEqual(state, .connected, "FakeMirroring with empty contentView children should report .connected")
    }

    func testGetOrientation() {
        let orientation = bridge.getOrientation()
        XCTAssertNotNil(orientation, "Should detect orientation from window dimensions")
        XCTAssertEqual(orientation, .portrait, "410x898 window should be portrait")
    }

    func testTriggerMenuAction() {
        // FakeMirroring has a View menu with "Spotlight" item
        let result = bridge.triggerMenuAction(menu: "View", item: "Spotlight")
        XCTAssertTrue(result, "Should be able to trigger View > Spotlight menu action via AX")
    }

    // MARK: - Screenshot Tests

    func testCaptureBase64() {
        let capture = ScreenCapture(bridge: bridge)
        let base64 = capture.captureBase64()
        XCTAssertNotNil(base64, "Should capture FakeMirroring window as base64 PNG")

        guard let base64 = base64 else { return }

        // PNG base64 starts with "iVBORw0KGgo"
        XCTAssertTrue(base64.hasPrefix("iVBORw0KGgo"), "Captured data should be a valid PNG (base64 prefix check)")
        XCTAssertGreaterThan(base64.count, 1000, "PNG should be a reasonable size (not a 1px placeholder)")
    }

    /// The real ScreenCaptureKit path answers a blocked synchronous caller —
    /// the shape of the `mirroir test` CLI — without timing out or falling back
    /// to the `screencapture` CLI.
    func testCaptureUsesScreenCaptureKitWithoutFallback() {
        let stats = CaptureStats()
        let capture = ScreenCapture(bridge: bridge, stats: stats)
        let start = Date()

        let result = capture.captureWithInfo()

        XCTAssertNotNil(result, "Should capture the FakeMirroring window")
        XCTAssertEqual(stats.snapshot().summaryLine, "capture: sck=1 fallback=0")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0,
                          "an SCK capture answers in well under the fallback timeout")
    }

    // MARK: - OCR Tests

    func testDescribeScreen() {
        let describer = ScreenDescriber(bridge: bridge, capture: ScreenCapture(bridge: bridge))
        let result = describer.describe()
        XCTAssertNotNil(result, "Should capture and describe FakeMirroring window")

        guard let result = result else { return }

        // Check that OCR found some of the rendered text
        let texts = result.elements.map { $0.text.lowercased() }
        let allText = texts.joined(separator: " ")

        // FakeMirroring renders settings-style labels at 18pt+ white on dark background
        let expectedLabels = ["settings", "general", "9:41"]
        for label in expectedLabels {
            XCTAssertTrue(
                allText.contains(label),
                "OCR should detect '\(label)' in FakeMirroring window. Found: \(texts)"
            )
        }

        // Screenshot should also be returned
        XCTAssertFalse(result.screenshotBase64.isEmpty, "Should include screenshot in describe result")
    }

    func testIconDetectionSkipsLabeledTabBar() {
        // Switch to a scenario whose root screen has a tab bar (Settings root
        // doesn't). The Feed fixture renders `hasTabBar: true`.
        IntegrationTestHelper.resetScenario(bridge: bridge, to: "Feed")
        let describer = ScreenDescriber(bridge: bridge, capture: ScreenCapture(bridge: bridge))
        guard let result = describer.describe() else {
            XCTFail("describe() returned nil")
            return
        }

        // FakeMirroring renders 5 tab bar icons WITH text labels below them.
        // The icon detector only detects icons in OCR-empty zones. Since the tab bar
        // now has OCR-detectable labels, the detector correctly skips it — the labels
        // are handled by TapPointCalculator's bottom-zone offset instead.
        // Any detected icons should NOT be in the tab bar area.
        let info = bridge.getWindowInfo()
        guard let info = info else { return }
        let windowHeight = Double(info.size.height)

        let tabBarThreshold = windowHeight * 0.90
        let tabBarIcons = result.icons.filter { $0.tapY > tabBarThreshold }
        XCTAssertEqual(
            tabBarIcons.count, 0,
            "Icon detector should skip labeled tab bar, but found \(tabBarIcons.count) icons there"
        )
    }

    func testTabBarLabelsGetTapOffset() {
        // Switch to a scenario with a tab bar — Settings root has none. Clock's
        // pack declares four tabs, and the bar draws their names.
        IntegrationTestHelper.resetScenario(bridge: bridge, to: "Clock")
        let describer = ScreenDescriber(bridge: bridge, capture: ScreenCapture(bridge: bridge))
        guard let result = describer.describe() else {
            XCTFail("describe() returned nil")
            return
        }

        let info = bridge.getWindowInfo()
        guard let info = info else {
            XCTFail("getWindowInfo() returned nil")
            return
        }
        let windowHeight = Double(info.size.height)

        // FakeMirroring renders Clock's 4 tab labels in the bottom zone.
        // TapPointCalculator classifies them as an icon row with
        // bottomZoneOffset (default 0), targeting textTopY directly.
        let tabBarNames = Set(["World Clock", "Alarms", "Stopwatch", "Timers"])
        // "Alarms" is also the screen title; only the bottom band is the bar.
        let tabBarElements = result.elements.filter {
            tabBarNames.contains($0.text) && $0.tapY > Double(info.size.height) * 0.8
        }

        XCTAssertGreaterThanOrEqual(
            tabBarElements.count, 3,
            "OCR should detect at least 3 tab bar labels, found: \(tabBarElements.map(\.text))"
        )

        // All tab bar labels should be in the bottom 15% of the window
        let bottomThreshold = windowHeight * 0.85
        for element in tabBarElements {
            XCTAssertGreaterThan(
                element.tapY, bottomThreshold * 0.8,
                "Tab bar label '\(element.text)' tapY=\(element.tapY) should be near bottom of window"
            )
        }

        // Tab bar labels use bottomZoneOffset (default 0) so tapY targets
        // textTopY directly — the entire tab button area is tappable and the
        // text position is the most reliable anchor from OCR.
        for element in tabBarElements {
            XCTAssertGreaterThan(
                element.tapY, bottomThreshold,
                "Tab bar label '\(element.text)' tapY=\(element.tapY) should be at the text "
                + "position in the bottom zone (> \(bottomThreshold))"
            )
        }
    }

    func testOCRCoordinateAccuracy() {
        let describer = ScreenDescriber(bridge: bridge, capture: ScreenCapture(bridge: bridge))
        guard let result = describer.describe() else {
            XCTFail("describe() returned nil")
            return
        }

        let info = bridge.getWindowInfo()
        XCTAssertNotNil(info, "Should have window info for bounds checking")
        guard let info = info else { return }

        let windowWidth = Double(info.size.width)
        let windowHeight = Double(info.size.height)

        for element in result.elements {
            XCTAssertGreaterThanOrEqual(
                element.tapX, 0,
                "Tap X for '\(element.text)' should be >= 0"
            )
            XCTAssertLessThanOrEqual(
                element.tapX, windowWidth,
                "Tap X for '\(element.text)' should be <= window width (\(windowWidth))"
            )
            XCTAssertGreaterThanOrEqual(
                element.tapY, 0,
                "Tap Y for '\(element.text)' should be >= 0"
            )
            XCTAssertLessThanOrEqual(
                element.tapY, windowHeight,
                "Tap Y for '\(element.text)' should be <= window height (\(windowHeight))"
            )
            XCTAssertGreaterThanOrEqual(
                element.confidence, 0.5,
                "Confidence for '\(element.text)' should be >= 0.5"
            )
        }
    }
}
