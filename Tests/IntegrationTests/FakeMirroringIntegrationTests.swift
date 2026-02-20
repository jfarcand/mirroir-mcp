// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Integration tests that exercise real macOS APIs against the FakeMirroring app.
// ABOUTME: Validates MirroringBridge, ScreenCapture, and ScreenDescriber using a live window.

import XCTest
import HelperLib
@testable import iphone_mirroir_mcp

/// Integration tests that require the FakeMirroring app to be running.
///
/// Run with:
/// ```
/// IPHONE_MIRROIR_BUNDLE_ID=com.jfarcand.FakeMirroring \
/// IPHONE_MIRROIR_PROCESS_NAME=FakeMirroring \
/// swift test --filter IntegrationTests
/// ```
final class FakeMirroringIntegrationTests: XCTestCase {

    private var bridge: MirroringBridge!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // These tests require FakeMirroring — skip when running against real iPhone Mirroring.
        // This is environment gating: the tests can only pass when FakeMirroring is configured
        // and running, which CI sets up explicitly.
        let bundleID = EnvConfig.mirroringBundleID
        try XCTSkipUnless(
            bundleID == "com.jfarcand.FakeMirroring",
            "Integration tests require IPHONE_MIRROIR_BUNDLE_ID=com.jfarcand.FakeMirroring"
        )

        bridge = MirroringBridge()

        guard bridge.findProcess() != nil else {
            XCTFail(
                "FakeMirroring app is not running. "
                + "Expected bundle ID: \(bundleID). "
                + "Launch it with: open .build/release/FakeMirroring.app"
            )
            return
        }
    }

    // MARK: - MirroringBridge Tests

    func testFindProcess() {
        let process = bridge.findProcess()
        XCTAssertNotNil(process, "Should find FakeMirroring process by bundle ID")
        XCTAssertEqual(process?.bundleIdentifier, EnvConfig.mirroringBundleID)
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

    // MARK: - OCR Tests

    func testDescribeScreen() {
        let describer = ScreenDescriber(bridge: bridge, capture: ScreenCapture(bridge: bridge))
        let result = describer.describe()
        XCTAssertNotNil(result, "Should capture and describe FakeMirroring window")

        guard let result = result else { return }

        // Check that OCR found some of the rendered text
        let texts = result.elements.map { $0.text.lowercased() }
        let allText = texts.joined(separator: " ")

        // These labels are rendered in FakeScreenView at 18pt white on dark background
        let expectedLabels = ["settings", "safari", "9:41"]
        for label in expectedLabels {
            XCTAssertTrue(
                allText.contains(label),
                "OCR should detect '\(label)' in FakeMirroring window. Found: \(texts)"
            )
        }

        // Screenshot should also be returned
        XCTAssertFalse(result.screenshotBase64.isEmpty, "Should include screenshot in describe result")
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
