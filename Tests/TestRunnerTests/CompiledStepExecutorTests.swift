// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for CompiledStepExecutor: replay of compiled steps using cached hints.
// ABOUTME: Validates OCR-free tap, sleep, scroll sequence, and passthrough delegation.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class CompiledStepExecutorTests: XCTestCase {

    private var bridge: StubBridge!
    private var input: StubInput!
    private var describer: StubDescriber!
    private var capture: StubCapture!
    private var compiledExecutor: CompiledStepExecutor!

    override func setUp() {
        super.setUp()
        bridge = StubBridge()
        input = StubInput()
        describer = StubDescriber()
        capture = StubCapture()

        let config = StepExecutorConfig(
            waitForTimeoutSeconds: 2,
            settlingDelayMs: 0,  // No delay in tests
            screenshotDir: NSTemporaryDirectory() + "test-compiled-\(UUID().uuidString)",
            dryRun: false
        )
        compiledExecutor = CompiledStepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: config
        )
    }

    // MARK: - Compiled Tap

    func testCompiledTapUsesCachedCoordinates() {
        let step = SkillStep.tap(label: "General")
        let compiledStep = CompiledStep(
            index: 0, type: "tap", label: "General",
            hints: .tap(x: 205.0, y: 340.5, confidence: 0.98, strategy: "exact")
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("compiled tap") ?? false)
        // Verify it tapped at the compiled coordinates, not via OCR
        XCTAssertEqual(input.tapCalls.count, 1)
        XCTAssertEqual(input.tapCalls[0].x, 205.0)
        XCTAssertEqual(input.tapCalls[0].y, 340.5)
    }

    func testCompiledTapDoesNotCallDescriber() {
        // Describer should NOT be called for a compiled tap
        describer.describeResult = nil  // Would fail if called

        let step = SkillStep.tap(label: "General")
        let compiledStep = CompiledStep(
            index: 0, type: "tap", label: "General",
            hints: .tap(x: 100, y: 200, confidence: 0.95, strategy: "exact")
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .passed)
    }

    func testCompiledTapMissingCoordinatesFails() {
        let step = SkillStep.tap(label: "General")
        let hints = StepHints(
            compiledAction: .tap, tapX: nil, tapY: nil,
            confidence: nil, matchStrategy: nil,
            observedDelayMs: nil, scrollCount: nil, scrollDirection: nil
        )
        let compiledStep = CompiledStep(
            index: 0, type: "tap", label: "General", hints: hints)

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("missing coordinates") ?? false)
    }

    func testCompiledTapInputError() {
        input.tapResult = "Helper not available"

        let step = SkillStep.tap(label: "General")
        let compiledStep = CompiledStep(
            index: 0, type: "tap", label: "General",
            hints: .tap(x: 100, y: 200, confidence: 0.95, strategy: "exact")
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "Helper not available")
    }

    // MARK: - Compiled Sleep

    func testCompiledSleepDoesNotCallDescriber() {
        describer.describeResult = nil  // Would fail if called for OCR

        let step = SkillStep.waitFor(label: "General", timeoutSeconds: nil)
        let compiledStep = CompiledStep(
            index: 0, type: "wait_for", label: "General",
            hints: .sleep(delayMs: 100)
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("compiled sleep") ?? false)
    }

    func testCompiledSleepWithZeroDelay() {
        let step = SkillStep.assertVisible(label: "OK")
        let compiledStep = CompiledStep(
            index: 0, type: "assert_visible", label: "OK",
            hints: .sleep(delayMs: 0)
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .passed)
    }

    // MARK: - Compiled Scroll Sequence

    func testCompiledScrollSequencePerformsCorrectSwipes() {
        let step = SkillStep.scrollTo(label: "About", direction: "up", maxScrolls: 10)
        let compiledStep = CompiledStep(
            index: 0, type: "scroll_to", label: "About",
            hints: .scrollSequence(count: 3, direction: "up")
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(input.swipeCalls.count, 3)
        XCTAssertTrue(result.message?.contains("3 scroll(s)") ?? false)
    }

    func testCompiledScrollSequenceZeroCount() {
        let step = SkillStep.scrollTo(label: "About", direction: "up", maxScrolls: 10)
        let compiledStep = CompiledStep(
            index: 0, type: "scroll_to", label: "About",
            hints: .scrollSequence(count: 0, direction: "up")
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(input.swipeCalls.count, 0)
        XCTAssertTrue(result.message?.contains("already visible") ?? false)
    }

    func testCompiledScrollSequenceNoWindowInfo() {
        bridge.windowInfo = nil

        let step = SkillStep.scrollTo(label: "About", direction: "up", maxScrolls: 10)
        let compiledStep = CompiledStep(
            index: 0, type: "scroll_to", label: "About",
            hints: .scrollSequence(count: 2, direction: "up")
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("window info") ?? false)
    }

    func testCompiledScrollSequenceSwipeError() {
        input.swipeResult = "Swipe failed"

        let step = SkillStep.scrollTo(label: "About", direction: "up", maxScrolls: 10)
        let compiledStep = CompiledStep(
            index: 0, type: "scroll_to", label: "About",
            hints: .scrollSequence(count: 2, direction: "up")
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .failed)
    }

    // MARK: - Passthrough

    func testPassthroughDelegatesToNormalExecutor() {
        input.launchAppResult = nil  // success

        let step = SkillStep.launch(appName: "Settings")
        let compiledStep = CompiledStep(
            index: 0, type: "launch", label: "Settings",
            hints: .passthrough()
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(input.launchAppCalls, ["Settings"])
    }

    func testPassthroughHomeStep() {
        bridge.menuActionResult = true

        let step = SkillStep.home
        let compiledStep = CompiledStep(
            index: 0, type: "home", label: nil,
            hints: .passthrough()
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .passed)
    }

    // MARK: - No Hints (AI-only)

    func testNoHintsSkipsStep() {
        let step = SkillStep.skipped(stepType: "remember", reason: "AI-only")
        let compiledStep = CompiledStep(
            index: 0, type: "remember", label: nil, hints: nil)

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test")

        XCTAssertEqual(result.status, .skipped)
        XCTAssertTrue(result.message?.contains("no compiled hints") ?? false)
    }

    // MARK: - RecordingDescriber

    func testRecordingDescriberCachesLastResult() {
        let inner = StubDescriber()
        let expected = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Test", tapX: 100, tapY: 200, confidence: 0.9)],
            screenshotBase64: ""
        )
        inner.describeResult = expected

        let recording = RecordingDescriber(wrapping: inner)
        XCTAssertNil(recording.lastResult)
        XCTAssertEqual(recording.callCount, 0)

        let result = recording.describe(skipOCR: false)
        XCTAssertEqual(result?.elements.count, 1)
        XCTAssertEqual(recording.lastResult?.elements.count, 1)
        XCTAssertEqual(recording.callCount, 1)
    }

    func testRecordingDescriberForwardsSkipOCR() {
        let inner = StubDescriber()
        inner.describeResult = ScreenDescriber.DescribeResult(elements: [], screenshotBase64: "")

        let recording = RecordingDescriber(wrapping: inner)
        _ = recording.describe(skipOCR: true)

        XCTAssertTrue(inner.lastSkipOCR)
    }

    func testRecordingDescriberHandlesNilResult() {
        let inner = StubDescriber()
        inner.describeResult = nil

        let recording = RecordingDescriber(wrapping: inner)
        let result = recording.describe(skipOCR: false)

        XCTAssertNil(result)
        XCTAssertNil(recording.lastResult)
        XCTAssertEqual(recording.callCount, 1)
    }
}
