// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for StepExecutor: each core step type with stub subsystems.
// ABOUTME: Validates launch, tap, type, assertions, navigation, dry run, and target switching.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class StepExecutorTests: XCTestCase {

    var bridge: StubBridge!
    var input: StubInput!
    var describer: StubDescriber!
    var capture: StubCapture!
    var executor: StepExecutor!

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

    // MARK: - Switch Target

    func testSwitchTargetWithoutRegistryFails() {
        // The default executor has no registry
        let result = executor.execute(
            step: .switchTarget(.ios(app: nil)), stepIndex: 0, skillName: "test")
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
            name: "iphone", targetType: "iphone-mirroring", bundleID: nil,
            bridge: bridge, input: input,
            capture: capture, describer: describer, recorder: StubRecorder(),
            capabilities: [.menuActions])
        let androidCtx = TargetContext(
            name: "android", targetType: "generic-window", bundleID: nil,
            bridge: bridge2, input: input2,
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
            step: .switchTarget(.macos(name: "android")), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("android") ?? false)
    }

    func testSwitchTargetUnknownFails() {
        let ctx = TargetContext(
            name: "iphone", targetType: "iphone-mirroring", bundleID: nil,
            bridge: bridge, input: input,
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
            step: .switchTarget(.macos(name: "nonexistent")), stepIndex: 0, skillName: "test")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("no target named 'nonexistent'") ?? false)
    }
}
