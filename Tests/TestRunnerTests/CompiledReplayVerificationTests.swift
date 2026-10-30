// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that compiled replay verifies each step on the live screen before passing it.
// ABOUTME: Covers labeled taps (at spot, moved, absent), live wait_for, and scroll_to target checks.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class CompiledReplayVerificationTests: XCTestCase {

    private var bridge: StubBridge!
    private var input: StubInput!
    private var describer: StubDescriber!
    private var executor: CompiledStepExecutor!

    override func setUp() {
        super.setUp()
        bridge = StubBridge()
        input = StubInput()
        describer = StubDescriber()
        let config = StepExecutorConfig(
            waitForTimeoutSeconds: 1,
            settlingDelayMs: 0,
            screenshotDir: NSTemporaryDirectory() + "test-replay-verify-\(UUID().uuidString)",
            dryRun: false
        )
        executor = CompiledStepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: StubCapture(),
            config: config
        )
    }

    // MARK: - Helpers

    private func screen(_ points: [TapPoint]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(elements: points, screenshotBase64: "")
    }

    private func element(_ text: String, x: Double, y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    private func run(_ step: SkillStep, _ hints: StepHints) -> StepResult {
        executor.execute(
            step: step,
            compiledStep: CompiledStep(index: 0, type: step.typeKey,
                                       label: step.labelValue, hints: hints),
            stepIndex: 0, skillName: "test")
    }

    private let generalTap = StepHints.tap(x: 205.0, y: 340.5, strategy: "exact")

    // MARK: - Labeled Tap

    func testLabelAtTheRecordedSpotTapsTheRecordedCoordinates() {
        let tolerance = EnvConfig.compiledTapPositionTolerance
        describer.describeResult = screen([
            element("General", x: 205.0 + tolerance, y: 340.5 - tolerance)])

        let result = run(.tap(label: "General"), generalTap)

        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("verified at recorded position") ?? false,
                      result.message ?? "")
        XCTAssertEqual(input.tapCalls.count, 1)
        XCTAssertEqual(input.tapCalls[0].x, 205.0)
        XCTAssertEqual(input.tapCalls[0].y, 340.5)
    }

    func testLabelThatMovedIsTappedWhereItIsNowAndSaysSo() {
        let tolerance = EnvConfig.compiledTapPositionTolerance
        let movedY = 340.5 + tolerance + 60
        describer.describeResult = screen([element("General", x: 205.0, y: movedY)])

        let result = run(.tap(label: "General"), generalTap)

        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("moved from recorded") ?? false,
                      result.message ?? "")
        XCTAssertEqual(input.tapCalls.count, 1)
        XCTAssertEqual(input.tapCalls[0].x, 205.0)
        XCTAssertEqual(input.tapCalls[0].y, movedY)
    }

    func testSameTextElsewhereDoesNotPullTheTapOffItsRecordedSpot() {
        // Clock: the "Alarmes" page title sits above the "Alarmes" tab that was recorded.
        describer.describeResult = screen([
            element("Alarmes", x: 93.0, y: 155.0),
            element("Alarmes", x: 164.0, y: 857.0)])

        let result = run(.tap(label: "Alarmes"), StepHints.tap(x: 164.0, y: 857.0, strategy: "exact"))

        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.message?.contains("verified at recorded position") ?? false,
                      result.message ?? "")
        XCTAssertEqual(input.tapCalls.count, 1)
        XCTAssertEqual(input.tapCalls[0].x, 164.0)
        XCTAssertEqual(input.tapCalls[0].y, 857.0)
    }

    func testAbsentLabelFailsWithoutTapping() {
        describer.describeResult = screen([element("Privacy", x: 205.0, y: 340.5)])

        let result = run(.tap(label: "General"), generalTap)

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("\"General\" not found") ?? false,
                      result.message ?? "")
        XCTAssertTrue(result.message?.contains("Privacy") ?? false, result.message ?? "")
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    func testFailedScreenCaptureFailsALabeledTapWithoutTapping() {
        describer.describeResult = nil

        let result = run(.tap(label: "General"), generalTap)

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("Failed to capture screen") ?? false)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    func testTapInputErrorFailsTheStep() {
        describer.describeResult = screen([element("General", x: 205.0, y: 340.5)])
        input.tapResult = "Helper not available"

        let result = run(.tap(label: "General"), generalTap)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "Helper not available")
    }

    func testTapHintOnAnotherStepTypeFailsWithoutTapping() {
        let result = run(.launch(appName: "Settings"), generalTap)

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("does not fit a launch step") ?? false,
                      result.message ?? "")
        XCTAssertTrue(input.tapCalls.isEmpty)
        XCTAssertTrue(input.launchAppCalls.isEmpty)
    }

    // MARK: - wait_for

    /// The hints `record_step` compiles a wait_for into, after it took 900ms to show.
    private func compiledWaitForHints() throws -> StepHints {
        let hints = try XCTUnwrap(MirroirMCP.deriveHints(
            type: "wait_for", tapX: nil, tapY: nil,
            matchStrategy: nil, elapsedMs: 900, scrollCount: nil, scrollDirection: nil))
        XCTAssertEqual(hints.compiledAction, .passthrough)
        return hints
    }

    /// A compiled wait_for polls the screen until its element shows.
    func testCompiledWaitForPassesOnceItsLabelAppears() throws {
        describer.describeResults = [
            screen([element("Loading", x: 100, y: 100)]),
            screen([element("About", x: 100, y: 200)]),
        ]

        let result = run(.waitFor(label: "About", timeoutSeconds: 1),
                         try compiledWaitForHints())

        XCTAssertEqual(result.status, .passed)
    }

    /// A compiled wait_for whose element never shows fails at its timeout.
    func testCompiledWaitForFailsWhenItsLabelNeverAppears() throws {
        describer.describeResult = screen([element("Loading", x: 100, y: 100)])

        let result = run(.waitFor(label: "About", timeoutSeconds: 1),
                         try compiledWaitForHints())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("Timed out waiting for \"About\"") ?? false,
                      result.message ?? "")
    }

    // MARK: - scroll_to

    func testZeroScrollsPassWhenTheTargetIsVisible() {
        describer.describeResult = screen([element("About", x: 100, y: 300)])

        let result = run(.scrollTo(label: "About", direction: "up", maxScrolls: 10),
                         .scrollSequence(count: 0, direction: "up"))

        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }

    func testMissingTargetGetsOneExtraScroll() {
        describer.describeResults = [
            screen([element("General", x: 100, y: 300)]),
            screen([element("About", x: 100, y: 300)]),
        ]

        let result = run(.scrollTo(label: "About", direction: "up", maxScrolls: 10),
                         .scrollSequence(count: 0, direction: "up"))

        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(input.swipeCalls.count, 1)
        XCTAssertTrue(result.message?.contains("after extra scroll") ?? false,
                      result.message ?? "")
    }

    func testTargetNeverVisibleFailsAfterTheExtraScroll() {
        describer.describeResult = screen([element("General", x: 100, y: 300)])

        let result = run(.scrollTo(label: "About", direction: "up", maxScrolls: 10),
                         .scrollSequence(count: 2, direction: "up"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(input.swipeCalls.count, 3)
        XCTAssertTrue(result.message?.contains("\"About\" not found") ?? false,
                      result.message ?? "")
    }

    func testFailedExtraScrollFailsTheStep() {
        describer.describeResult = screen([element("General", x: 100, y: 300)])
        input.swipeResult = "Swipe failed"

        let result = run(.scrollTo(label: "About", direction: "up", maxScrolls: 10),
                         .scrollSequence(count: 0, direction: "up"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("extra scroll failed") ?? false,
                      result.message ?? "")
    }

    func testScrollHintOnAnotherStepTypeFailsWithoutScrolling() {
        let result = run(.tap(label: "General"), .scrollSequence(count: 2, direction: "up"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(input.swipeCalls.isEmpty)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }
}
