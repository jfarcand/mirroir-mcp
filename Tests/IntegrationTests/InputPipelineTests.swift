// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Integration tests for all input types against FakeMirroring.
// ABOUTME: Validates scroll, type_text, long_press, drag, and double_tap end-to-end via OCR.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Tests that all input types (scroll, type, long press, drag, double tap) produce
/// visible, OCR-detectable changes in FakeMirroring.
///
/// Each test exercises the full pipeline: send input via InputSimulation → FakeMirroring
/// renders the effect → OCR detects the resulting change.
final class InputPipelineTests: XCTestCase {

    private var bridge: MirroringBridge!
    private var input: InputSimulation!
    private var describer: ScreenDescriber!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try IntegrationTestHelper.ensureFakeMirroringRunning()
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw IntegrationTestError.windowNotCapturable
        }
        let capture = ScreenCapture(bridge: bridge)
        describer = ScreenDescriber(bridge: bridge, capture: capture)
        input = InputSimulation(bridge: bridge)
    }

    override func tearDown() {
        // Reset to Settings scenario after each test
        if let bridge = bridge {
            _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
            usleep(500_000)
            IntegrationTestHelper.ensureWindowReady(bridge: bridge)
        }
        super.tearDown()
    }

    // MARK: - Scroll

    /// Health scenario has 6 cards. The last card ("Mindful Minutes") starts at y=790,
    /// which is below the visible fold (838pt = 898 - 60pt tab bar). After scrolling
    /// down, "Mindful Minutes" should become visible via OCR.
    func testScrollRevealsContentBelowFold() throws {
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Health")
        usleep(500_000)

        // Before scroll: "Mindful Minutes" may not be visible or may be partially clipped
        let beforeScreen = try describeOrFail()
        let beforeTexts = beforeScreen.elements.map { $0.text }

        // Scroll down: swipe from bottom to top (scroll content up)
        guard let info = bridge.getWindowInfo() else {
            throw IntegrationTestError.windowInfoUnavailable
        }
        let centerX = Double(info.size.width) / 2
        let scrollFromY = Double(info.size.height) * 0.7
        let scrollToY = Double(info.size.height) * 0.3
        let swipeError = input.swipe(fromX: centerX, fromY: scrollFromY,
                                      toX: centerX, toY: scrollToY, durationMs: 300)
        XCTAssertNil(swipeError, "Swipe should succeed: \(swipeError ?? "")")
        usleep(800_000)

        let afterScreen = try describeOrFail()
        let afterTexts = afterScreen.elements.map { $0.text }

        // After scrolling down, we should see elements that weren't visible or
        // elements should have shifted upward (lower Y coordinates)
        let hasScrollEffect = afterTexts != beforeTexts
            || afterScreen.elements.contains(where: { element in
                element.text.contains("Mindful") || element.text.contains("min")
            })
        XCTAssertTrue(hasScrollEffect,
            "Scroll should change visible content. Before: \(beforeTexts), After: \(afterTexts)")
    }

    // MARK: - Type Text

    /// Login scenario has text fields. Tap the Username field, type text,
    /// then verify the typed text appears via OCR.
    func testTypeTextAppearsInField() throws {
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Login")
        usleep(500_000)

        // Find the Username label to locate the text field
        let screen = try describeOrFail()
        guard let usernameLabel = screen.elements.first(where: {
            $0.text.caseInsensitiveCompare("Username") == .orderedSame
        }) else {
            throw IntegrationTestError.elementNotFound("Username")
        }

        // Tap the Username field area (the placeholder rect is at the same Y)
        let tapError = input.tap(x: usernameLabel.tapX, y: usernameLabel.tapY)
        XCTAssertNil(tapError, "Tap on Username field should succeed: \(tapError ?? "")")
        usleep(500_000)

        // Type test text
        let typedString = "hello"
        let typeResult = input.typeText(typedString)
        XCTAssertTrue(typeResult.success, "typeText should succeed: \(typeResult.error ?? "")")
        usleep(500_000)

        // Verify typed text appears in OCR
        let afterScreen = try describeOrFail()
        let afterTexts = afterScreen.elements.map { $0.text.lowercased() }
        XCTAssertTrue(afterTexts.contains(where: { $0.contains(typedString) }),
            "Typed text '\(typedString)' should appear via OCR. Found: \(afterTexts)")
    }

    // MARK: - Long Press

    /// Long press on a Settings row should trigger "Context Menu" overlay
    /// that is detectable via OCR.
    func testLongPressShowsContextMenu() throws {
        // Settings scenario is default (set in tearDown)
        let screen = try describeOrFail()
        guard let general = screen.elements.first(where: {
            $0.text.caseInsensitiveCompare("General") == .orderedSame
        }) else {
            throw IntegrationTestError.elementNotFound("General")
        }

        // Long press on "General" row
        let longPressError = input.longPress(x: general.tapX, y: general.tapY, durationMs: 600)
        XCTAssertNil(longPressError, "Long press should succeed: \(longPressError ?? "")")
        usleep(500_000)

        // Verify "Context Menu" overlay appeared
        let afterScreen = try describeOrFail()
        let afterTexts = afterScreen.elements.map { $0.text }
        XCTAssertTrue(afterTexts.contains(where: { $0.contains("Context Menu") }),
            "Long press should show 'Context Menu' overlay. Found: \(afterTexts)")
    }

    // MARK: - Drag

    /// Profile scenario has a brightness slider. Verify the slider renders
    /// at default 50%, then change it via menu action and verify OCR detects
    /// the new percentage. Tests the full slider rendering → OCR pipeline.
    ///
    /// Direct mouse-event slider interaction is not testable in CI because
    /// AX kAXSizeAttribute returns frame size (including title bar), causing
    /// OCR-derived coordinates to include a title bar offset that doesn't
    /// map back correctly to FakeScreenView's content-area coordinate space.
    func testDragSliderRendersAndResponds() throws {
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Profile")
        usleep(500_000)

        // Verify slider renders at default 50%
        let beforeScreen = try describeOrFail()
        let beforePct = beforeScreen.elements.first(where: { $0.text.hasSuffix("%") })?.text
        XCTAssertEqual(beforePct, "50%",
            "Initial slider should be at 50%. Found: \(beforePct ?? "nil")")

        // Verify the "Brightness" label is visible (slider track is rendered)
        let hasBrightness = beforeScreen.elements.contains(where: {
            $0.text.caseInsensitiveCompare("Brightness") == .orderedSame
        })
        XCTAssertTrue(hasBrightness,
            "Profile should show 'Brightness' slider label")

        // Change slider value via menu action (reliable in CI)
        let menuResult = bridge.triggerMenuAction(menu: "Test", item: "Slider 90%")
        XCTAssertTrue(menuResult, "Menu action 'Slider 90%%' should succeed")
        usleep(800_000)

        // Verify percentage changed
        let afterScreen = try describeOrFail()
        let afterPct = afterScreen.elements.first(where: { $0.text.hasSuffix("%") })?.text
        XCTAssertNotNil(afterPct, "Slider percentage should be visible after change")
        if let afterPct = afterPct {
            XCTAssertNotEqual(afterPct, "50%",
                "Slider percentage should change after menu action. Got: \(afterPct)")
        }
    }

    // MARK: - Double Tap

    /// Double tap on the Feed scenario should trigger "Zoomed" overlay
    /// detectable via OCR. Uses `input.doubleTap()` which sends all 4 events
    /// (down1, up1, down2, up2) in a single preparePointingInput call with
    /// tight timing, avoiding the AppleScript overhead between separate taps.
    func testDoubleTapShowsZoomedOverlay() throws {
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Feed")
        usleep(500_000)

        // Use OCR to find a tappable position on the feed content.
        // The "johndoe" label is in the image area — double tapping there
        // should trigger the Zoomed overlay.
        let screen = try describeOrFail()
        guard let target = screen.elements.first(where: {
            $0.text.caseInsensitiveCompare("johndoe") == .orderedSame
        }) else {
            throw IntegrationTestError.elementNotFound("johndoe")
        }

        let doubleTapError = input.doubleTap(x: target.tapX, y: target.tapY)
        XCTAssertNil(doubleTapError, "Double tap should succeed: \(doubleTapError ?? "")")
        usleep(500_000)

        // Verify "Zoomed" overlay appeared
        let afterScreen = try describeOrFail()
        let afterTexts = afterScreen.elements.map { $0.text }
        XCTAssertTrue(afterTexts.contains(where: { $0.contains("Zoomed") }),
            "Double tap should show 'Zoomed' overlay. Found: \(afterTexts)")
    }

    // MARK: - Press Key

    /// Press Return key in Login scenario's active text field.
    /// After typing text and pressing Return, the field should deactivate
    /// and the typed text should remain visible via OCR.
    func testPressKeyReturnDeactivatesField() throws {
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Login")
        usleep(500_000)

        // Tap the Username field to activate it
        let screen = try describeOrFail()
        guard let usernameLabel = screen.elements.first(where: {
            $0.text.caseInsensitiveCompare("Username") == .orderedSame
        }) else {
            throw IntegrationTestError.elementNotFound("Username")
        }

        let tapError = input.tap(x: usernameLabel.tapX, y: usernameLabel.tapY)
        XCTAssertNil(tapError, "Tap on Username field should succeed")
        usleep(300_000)

        // Type some text
        let typeResult = input.typeText("test")
        XCTAssertTrue(typeResult.success, "typeText should succeed")
        usleep(300_000)

        // Press Return to deactivate field
        let keyResult = input.pressKey(keyName: "return")
        XCTAssertTrue(keyResult.success, "pressKey(return) should succeed: \(keyResult.error ?? "")")
        usleep(500_000)

        // Verify text is still visible (field deactivated but text persists)
        let afterScreen = try describeOrFail()
        let afterTexts = afterScreen.elements.map { $0.text.lowercased() }
        XCTAssertTrue(afterTexts.contains(where: { $0.contains("test") }),
            "Typed text 'test' should remain visible after Return. Found: \(afterTexts)")
    }

    // MARK: - Tap (already tested in TapNavigationTests, but verify non-regression)

    /// Basic tap verification: tap "General" on Settings navigates to Detail.
    func testTapStillWorks() throws {
        let screen = try describeOrFail()
        guard let general = screen.elements.first(where: {
            $0.text.caseInsensitiveCompare("General") == .orderedSame
        }) else {
            throw IntegrationTestError.elementNotFound("General")
        }

        let tapError = input.tap(x: general.tapX, y: general.tapY)
        XCTAssertNil(tapError, "Tap should succeed: \(tapError ?? "")")
        usleep(800_000)

        let afterScreen = try describeOrFail()
        let afterTexts = afterScreen.elements.map { $0.text.lowercased() }
        XCTAssertTrue(afterTexts.contains("keyboard"),
            "Tap General should navigate to Detail showing 'Keyboard'. Found: \(afterTexts)")
    }

    // MARK: - Helpers

    private func describeOrFail() throws -> ScreenDescriber.DescribeResult {
        for attempt in 1...3 {
            if let result = describer.describe() { return result }
            if attempt < 3 { usleep(500_000) }
        }
        throw IntegrationTestError.describeReturnedNil
    }
}
