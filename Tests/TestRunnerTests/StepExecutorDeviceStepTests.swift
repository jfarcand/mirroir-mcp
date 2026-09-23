// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for StepExecutor device-level steps: scroll_to, reset_app, set_network, and measure.
// ABOUTME: Uses the stub subsystems from StepExecutorTests to verify OCR-driven step execution.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

extension StepExecutorTests {

    // MARK: - scroll_to

    func testScrollToAlreadyVisible() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "About", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )

        let result = executor.execute(
            step: .scrollTo(label: "About", direction: "up", maxScrolls: 10),
            stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(result.message, "already visible")
        XCTAssertEqual(input.swipeCalls.count, 0)
    }

    func testScrollToFoundAfterScrolls() {
        // First call: no match; second call (after swipe): no match; third call: found
        let noMatch = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "General", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )
        let differentContent = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Privacy", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )
        let found = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "About", tapX: 100, tapY: 300, confidence: 0.95)],
            screenshotBase64: ""
        )
        describer.describeResults = [noMatch, noMatch, differentContent, found]

        let result = executor.execute(
            step: .scrollTo(label: "About", direction: "up", maxScrolls: 10),
            stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("scroll(s)") ?? false)
        XCTAssertTrue(input.swipeCalls.count > 0)
    }

    func testScrollToExhausted() {
        // Return same content every time — triggers scroll exhaustion
        let sameContent = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "General", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )
        describer.describeResult = sameContent

        let result = executor.execute(
            step: .scrollTo(label: "About", direction: "up", maxScrolls: 5),
            stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("exhausted") ?? false)
    }

    func testScrollToMaxReached() {
        // Different content each time but target never found
        let page1 = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Page1", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )
        let page2 = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Page2", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )
        let page3 = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Page3", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )
        // Initial check, then 2 scroll attempts (each needs check + post-swipe OCR)
        describer.describeResults = [page1, page1, page2, page2, page3]

        let result = executor.execute(
            step: .scrollTo(label: "Target", direction: "up", maxScrolls: 2),
            stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("Not found after") ?? false)
    }

    func testScrollToNoWindowInfo() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [], screenshotBase64: ""
        )
        bridge.windowInfo = nil

        let result = executor.execute(
            step: .scrollTo(label: "About", direction: "up", maxScrolls: 5),
            stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("window info") ?? false)
    }

    // MARK: - reset_app

    /// describe() sequence for a successful reset: foreground OCR, App Switcher
    /// OCR (the card present at window center, x=200), then the post-drag verify
    /// OCR with the card gone — so `AppSwitcherCardLocator` returns nil and the
    /// dismissal is confirmed rather than reported as a stuck card.
    private func resetDescribeSequence(cardText: String) -> [ScreenDescriber.DescribeResult?] {
        // Several clustered lines: a real screen renders enough text to pass
        // the foreground-readiness gate (appForegroundReadyMinElements), and a
        // real card preview shares several lines with the foreground capture —
        // AppSwitcherCardLocator requires minimum matched-text evidence, so a
        // lone short token must not locate a card.
        let withCard = ScreenDescriber.DescribeResult(
            elements: [
                TapPoint(text: cardText, tapX: 200, tapY: 400, confidence: 0.95),
                TapPoint(text: "General preview row", tapX: 205, tapY: 430, confidence: 0.95),
                TapPoint(text: "Second preview row", tapX: 203, tapY: 460, confidence: 0.95),
                TapPoint(text: "Third preview row", tapX: 207, tapY: 490, confidence: 0.95),
                TapPoint(text: "Fourth preview row", tapX: 204, tapY: 520, confidence: 0.95),
            ],
            screenshotBase64: "")
        let cardGone = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "OtherApp", tapX: 200, tapY: 400, confidence: 0.95)],
            screenshotBase64: "")
        return [withCard, withCard, cardGone]
    }

    func testResetAppForceQuit() {
        // describe() order: foreground OCR, App Switcher OCR (locate), then the
        // post-drag verify — which must show the card gone for the dismiss to
        // be reported as successful.
        describer.describeResults = resetDescribeSequence(cardText: "Settings")

        let result = executor.execute(
            step: .resetApp(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("Force-quit") ?? false)
        // Verify App Switcher was opened and Home was pressed
        XCTAssertTrue(bridge.menuActionCalls.contains(where: { $0.item == "App Switcher" }))
        XCTAssertTrue(bridge.menuActionCalls.contains(where: { $0.item == "Home Screen" }))
        // Verify drag up was performed on app card (drag, not swipe, for reliable dismiss)
        XCTAssertEqual(input.swipeCalls.count, 0)
        XCTAssertEqual(input.dragCalls.count, 1)
    }

    func testResetAppLaunchesViaSpotlight() {
        // The launch-first approach launches the app via Spotlight before
        // opening the App Switcher, so the target is always the centered card.
        describer.describeResults = resetDescribeSequence(cardText: "Settings")

        let result = executor.execute(
            step: .resetApp(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(input.launchAppCalls, ["Settings"])
    }

    func testResetAppLaunchFailure() {
        // If Spotlight fails to launch the app, reset_app should fail gracefully.
        input.launchAppResult = "App not found"

        let result = executor.execute(
            step: .resetApp(appName: "NonExistent"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("Failed to launch") ?? false)
    }

    func testResetAppNoCarouselSearch() {
        // The launch-first approach never searches the carousel via OCR,
        // so there should be zero horizontal swipes.
        describer.describeResults = resetDescribeSequence(cardText: "Settings")

        let result = executor.execute(
            step: .resetApp(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(input.swipeCalls.count, 0, "Launch-first approach should not swipe the carousel")
        XCTAssertEqual(input.dragCalls.count, 1, "Should drag up to dismiss the centered card")
    }

    func testResetAppSwitcherFailed() {
        // Foreground OCR succeeds (so the helper proceeds past the launch
        // step), but the AX menu action returns false → helper aborts before
        // opening App Switcher and reports the menu failure.
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [
                TapPoint(text: "Settings", tapX: 200, tapY: 400, confidence: 0.95),
                TapPoint(text: "General row", tapX: 205, tapY: 430, confidence: 0.95),
                TapPoint(text: "Display row", tapX: 203, tapY: 460, confidence: 0.95),
                TapPoint(text: "Privacy row", tapX: 207, tapY: 490, confidence: 0.95),
                TapPoint(text: "Battery row", tapX: 204, tapY: 520, confidence: 0.95),
            ],
            screenshotBase64: ""
        )
        bridge.menuActionResult = false

        let result = executor.execute(
            step: .resetApp(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("App Switcher") ?? false,
                      "Expected error message to mention App Switcher; got \(result.message ?? "")")
        XCTAssertEqual(input.dragCalls.count, 0, "Must not drag when App Switcher cannot be opened")
    }

    func testResetAppFailsClosedOnNilOCR() {
        // When the foreground OCR capture returns nil (after launch),
        // reset_app must abort before touching the App Switcher — never
        // open it and never drag.
        describer.describeResult = nil

        let result = executor.execute(
            step: .resetApp(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("OCR") ?? false,
                      "Expected message to mention OCR; got \(result.message ?? "")")
        XCTAssertEqual(input.dragCalls.count, 0, "Must not drag when OCR fails")
        XCTAssertFalse(bridge.menuActionCalls.contains(where: { $0.item == "App Switcher" }),
                       "Must not open App Switcher when foreground OCR fails")
    }

    func testResetAppEmptySwitcher() {
        // When OCR returns an empty result (foreground app exposes no
        // recognizable text yet), reset_app should fail closed without
        // dragging — we have no fingerprint to match a card with.
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [],
            screenshotBase64: ""
        )

        let result = executor.execute(
            step: .resetApp(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("OCR") ?? false,
                      "Expected message to mention OCR; got \(result.message ?? "")")
        XCTAssertEqual(input.dragCalls.count, 0, "Must not drag when foreground OCR is empty")
    }

    func testResetAppFailsClosedWhenLocatorMissesCard() {
        // App Switcher OCR has cards, but none of them match the launched
        // app's foreground text — locator returns nil → must NOT fall back
        // to a hard-coded x-fraction and drag a guess.
        let foreground = [
            TapPoint(text: "AmbiguousApp", tapX: 200, tapY: 400, confidence: 0.95),
            TapPoint(text: "First content row", tapX: 205, tapY: 430, confidence: 0.95),
            TapPoint(text: "Second content row", tapX: 203, tapY: 460, confidence: 0.95),
            TapPoint(text: "Third content row", tapX: 207, tapY: 490, confidence: 0.95),
            TapPoint(text: "Fourth content row", tapX: 204, tapY: 520, confidence: 0.95),
        ]
        let switcherCard = TapPoint(text: "SomethingElse", tapX: 300, tapY: 300, confidence: 0.9)
        describer.describeResults = [
            ScreenDescriber.DescribeResult(elements: foreground, screenshotBase64: ""),
            ScreenDescriber.DescribeResult(elements: [switcherCard], screenshotBase64: ""),
        ]

        let result = executor.execute(
            step: .resetApp(appName: "AmbiguousApp"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.lowercased().contains("locate") ?? false,
                      "Expected message to mention card-locate failure; got \(result.message ?? "")")
        XCTAssertEqual(input.dragCalls.count, 0, "Must not drag when card cannot be located")
    }

    func testResetAppWorksWithLocalizedName() {
        // Spotlight resolves localization (e.g. "Settings" → "Réglages").
        // The App Switcher card shows the localized name, not the English
        // name the caller passed. reset_app should still swipe because it
        // trusts the Spotlight launch rather than matching names.
        describer.describeResults = resetDescribeSequence(cardText: "Réglages")

        let result = executor.execute(
            step: .resetApp(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("Force-quit") ?? false)
        XCTAssertEqual(input.dragCalls.count, 1, "Should swipe regardless of display language")
    }

    // MARK: - set_network

    func testSetNetworkAirplaneOn() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Airplane Mode", tapX: 200, tapY: 150, confidence: 0.95)],
            screenshotBase64: ""
        )

        let result = executor.execute(
            step: .setNetwork(mode: "airplane_on"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("airplane_on") ?? false)
        XCTAssertEqual(input.launchAppCalls, ["Settings"])
        XCTAssertEqual(input.tapCalls.count, 1)
    }

    func testSetNetworkInvalidMode() {
        let result = executor.execute(
            step: .setNetwork(mode: "bluetooth_on"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("Unknown mode") ?? false)
    }

    func testSetNetworkSettingsLaunchFailed() {
        input.launchAppResult = "Spotlight failed"

        let result = executor.execute(
            step: .setNetwork(mode: "wifi_off"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("Settings") ?? false)
    }

    func testSetNetworkTargetNotFound() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "General", tapX: 200, tapY: 150, confidence: 0.95)],
            screenshotBase64: ""
        )

        let result = executor.execute(
            step: .setNetwork(mode: "cellular_off"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("not found") ?? false)
    }

    // MARK: - measure

    func testMeasureSuccess() {
        // Action (tap) needs OCR, then measure polling needs OCR with target
        let actionScreen = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Login", tapX: 200, tapY: 400, confidence: 0.95)],
            screenshotBase64: ""
        )
        let targetScreen = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Dashboard", tapX: 200, tapY: 100, confidence: 0.95)],
            screenshotBase64: ""
        )
        describer.describeResults = [actionScreen, targetScreen]

        let result = executor.execute(
            step: .measure(name: "login_time", action: .tap(label: "Login"),
                           until: "Dashboard", maxSeconds: 5.0),
            stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("login_time") ?? false)
    }

    func testMeasureActionFailed() {
        describer.describeResult = nil  // OCR fails, so tap action fails

        let result = executor.execute(
            step: .measure(name: "test", action: .tap(label: "Login"),
                           until: "Dashboard", maxSeconds: 5.0),
            stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("Action failed") ?? false)
    }

    func testMeasureTimeout() {
        let actionScreen = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Login", tapX: 200, tapY: 400, confidence: 0.95)],
            screenshotBase64: ""
        )
        // Target never appears
        let noTarget = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Loading", tapX: 200, tapY: 300, confidence: 0.95)],
            screenshotBase64: ""
        )
        describer.describeResults = [actionScreen, noTarget]

        // Use a very short timeout
        let shortConfig = StepExecutorConfig(
            waitForTimeoutSeconds: 1,
            settlingDelayMs: 0,
            screenshotDir: NSTemporaryDirectory(),
            dryRun: false
        )
        let shortExecutor = StepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: shortConfig
        )

        let result = shortExecutor.execute(
            step: .measure(name: "test", action: .tap(label: "Login"),
                           until: "Dashboard", maxSeconds: 0.5),
            stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("timed out") ?? false)
    }
}
