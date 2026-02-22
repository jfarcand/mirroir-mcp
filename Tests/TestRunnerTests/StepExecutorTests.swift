// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for StepExecutor: each step type with stub subsystems.
// ABOUTME: Validates step execution logic, OCR matching, and failure handling.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class StepExecutorTests: XCTestCase {

    private var bridge: StubBridge!
    private var input: StubInput!
    private var describer: StubDescriber!
    private var capture: StubCapture!
    private var executor: StepExecutor!

    override func setUp() {
        super.setUp()
        bridge = StubBridge()
        input = StubInput()
        describer = StubDescriber()
        capture = StubCapture()

        let config = StepExecutorConfig(
            waitForTimeoutSeconds: 2,
            settlingDelayMs: 0,  // No delay in tests
            screenshotDir: NSTemporaryDirectory() + "test-screenshots-\(UUID().uuidString)",
            dryRun: false
        )
        executor = StepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: config
        )
    }

    // MARK: - Launch

    func testLaunchSuccess() {
        input.launchAppResult = nil  // nil = success
        let result = executor.execute(
            step: .launch(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
    }

    func testLaunchFailure() {
        input.launchAppResult = "App not found"
        let result = executor.execute(
            step: .launch(appName: "NonExistent"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "App not found")
    }

    // MARK: - Tap

    func testTapSuccess() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "General", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )
        input.tapResult = nil  // nil = success

        let result = executor.execute(
            step: .tap(label: "General"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
    }

    func testTapElementNotFound() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "About", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )

        let result = executor.execute(
            step: .tap(label: "General"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("not found") ?? false)
    }

    func testTapOCRFailed() {
        describer.describeResult = nil

        let result = executor.execute(
            step: .tap(label: "General"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("OCR") ?? false)
    }

    // MARK: - Type

    func testTypeSuccess() {
        input.typeTextResult = TypeResult(success: true, warning: nil, error: nil)
        let result = executor.execute(
            step: .type(text: "Hello"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
    }

    func testTypeFailure() {
        input.typeTextResult = TypeResult(success: false, warning: nil, error: "Helper unavailable")
        let result = executor.execute(
            step: .type(text: "Hello"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
    }

    // MARK: - Press Key

    func testPressKeySuccess() {
        input.pressKeyResult = TypeResult(success: true, warning: nil, error: nil)
        let result = executor.execute(
            step: .pressKey(keyName: "return", modifiers: []),
            stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
    }

    // MARK: - Assert Visible

    func testAssertVisiblePass() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Model Name", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )

        let result = executor.execute(
            step: .assertVisible(label: "Model Name"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
    }

    func testAssertVisibleFail() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Other", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )

        let result = executor.execute(
            step: .assertVisible(label: "Model Name"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
    }

    // MARK: - Assert Not Visible

    func testAssertNotVisiblePass() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "General", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )

        let result = executor.execute(
            step: .assertNotVisible(label: "Error"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
    }

    func testAssertNotVisibleFail() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Error", tapX: 100, tapY: 200, confidence: 0.95)],
            screenshotBase64: ""
        )

        let result = executor.execute(
            step: .assertNotVisible(label: "Error"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
    }

    // MARK: - Home

    func testHomeSuccess() {
        bridge.menuActionResult = true
        let result = executor.execute(
            step: .home, stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
    }

    func testHomeFailure() {
        bridge.menuActionResult = false
        let result = executor.execute(
            step: .home, stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
    }

    // MARK: - Shake

    func testShakeSuccess() {
        input.shakeResult = TypeResult(success: true, warning: nil, error: nil)
        let result = executor.execute(
            step: .shake, stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
    }

    // MARK: - Open URL

    func testOpenURLSuccess() {
        input.openURLResult = nil  // nil = success
        let result = executor.execute(
            step: .openURL(url: "https://example.com"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
    }

    // MARK: - Swipe

    func testSwipeSuccess() {
        input.swipeResult = nil  // nil = success
        let result = executor.execute(
            step: .swipe(direction: "up"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
    }

    func testSwipeInvalidDirection() {
        let result = executor.execute(
            step: .swipe(direction: "diagonal"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("Unknown swipe direction") ?? false)
    }

    // MARK: - Skipped

    func testSkippedStep() {
        let result = executor.execute(
            step: .skipped(stepType: "remember", reason: "AI-only"),
            stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .skipped)
    }

    // MARK: - Dry Run

    func testDryRunSkipsExecution() {
        let dryConfig = StepExecutorConfig(
            waitForTimeoutSeconds: 2,
            settlingDelayMs: 0,
            screenshotDir: NSTemporaryDirectory(),
            dryRun: true
        )
        let dryExecutor = StepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: dryConfig
        )

        // This would fail normally since describer returns nil,
        // but dry run should pass.
        describer.describeResult = nil
        let result = dryExecutor.execute(
            step: .tap(label: "General"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(result.message, "dry run")
    }

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

    func testResetAppForceQuit() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Settings", tapX: 200, tapY: 400, confidence: 0.95)],
            screenshotBase64: ""
        )

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

    func testResetAppNotInSwitcher() {
        // App not found — exhausts all horizontal search swipes before reporting "already quit"
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Other App", tapX: 200, tapY: 400, confidence: 0.95)],
            screenshotBase64: ""
        )

        let result = executor.execute(
            step: .resetApp(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("already quit") ?? false)
        // Should have swiped left through the carousel before giving up
        XCTAssertEqual(input.swipeCalls.count, EnvConfig.appSwitcherMaxSwipes)
    }

    func testResetAppFindsAppAfterSwipe() {
        // First OCR: only "Other App" visible. After one horizontal swipe: "Settings" appears.
        let noMatch = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Other App", tapX: 200, tapY: 400, confidence: 0.95)],
            screenshotBase64: ""
        )
        let found = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Settings", tapX: 200, tapY: 400, confidence: 0.95)],
            screenshotBase64: ""
        )
        describer.describeResults = [noMatch, found]

        let result = executor.execute(
            step: .resetApp(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("Force-quit") ?? false)
        // 1 horizontal search swipe + 1 dismiss drag = 1 swipe + 1 drag
        XCTAssertEqual(input.swipeCalls.count, 1)
        XCTAssertEqual(input.dragCalls.count, 1)
    }

    func testResetAppExhaustsSwipesReportsAlreadyQuit() {
        // Target never appears across all carousel swipes
        let noMatch = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Other App", tapX: 200, tapY: 400, confidence: 0.95)],
            screenshotBase64: ""
        )
        describer.describeResult = noMatch

        let result = executor.execute(
            step: .resetApp(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("already quit") ?? false)
        // All swipes are horizontal search swipes, no dismiss swipe
        XCTAssertEqual(input.swipeCalls.count, EnvConfig.appSwitcherMaxSwipes)
    }

    func testResetAppSwitcherFailed() {
        bridge.menuActionResult = false

        let result = executor.execute(
            step: .resetApp(appName: "Settings"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("App Switcher") ?? false)
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

    // MARK: - Switch Target

    func testSwitchTargetWithoutRegistryFails() {
        // The default executor has no registry
        let result = executor.execute(
            step: .switchTarget(name: "android"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("No target registry") ?? false)
    }

    func testSwitchTargetWithRegistrySuccess() {
        let bridge2 = StubBridge()
        bridge2.targetName = "android"
        let input2 = StubInput()
        let describer2 = StubDescriber()
        let capture2 = StubCapture()

        let iphoneCtx = TargetContext(
            name: "iphone", bridge: bridge, input: input,
            capture: capture, describer: describer, recorder: StubRecorder(),
            capabilities: [.menuActions])
        let androidCtx = TargetContext(
            name: "android", bridge: bridge2, input: input2,
            capture: capture2, describer: describer2, recorder: StubRecorder(),
            capabilities: [])
        let registry = TargetRegistry(
            targets: ["iphone": iphoneCtx, "android": androidCtx],
            defaultName: "iphone")

        let config = StepExecutorConfig(
            waitForTimeoutSeconds: 2, settlingDelayMs: 0,
            screenshotDir: NSTemporaryDirectory() + "test-switch-\(UUID().uuidString)",
            dryRun: false)
        let registryExecutor = StepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: config, registry: registry)

        let result = registryExecutor.execute(
            step: .switchTarget(name: "android"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("android") ?? false)
    }

    func testSwitchTargetUnknownFails() {
        let ctx = TargetContext(
            name: "iphone", bridge: bridge, input: input,
            capture: capture, describer: describer, recorder: StubRecorder(),
            capabilities: [.menuActions])
        let registry = TargetRegistry(targets: ["iphone": ctx], defaultName: "iphone")

        let config = StepExecutorConfig(
            waitForTimeoutSeconds: 2, settlingDelayMs: 0,
            screenshotDir: NSTemporaryDirectory() + "test-switch-\(UUID().uuidString)",
            dryRun: false)
        let registryExecutor = StepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: config, registry: registry)

        let result = registryExecutor.execute(
            step: .switchTarget(name: "nonexistent"), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("Unknown target") ?? false)
    }
}
