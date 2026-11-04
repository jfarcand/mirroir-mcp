// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests SceneLoop's mechanics: OCR predicates decide pass and fail, the budget stops play, one touch per frame.
// ABOUTME: The vision model is a documented stub: a paid, non-deterministic model cannot run in a unit test.

import CoreGraphics
import HelperLib
import XCTest
@testable import mirroir_mcp

/// Stands in for the scene's vision model, which is paid and non-deterministic:
/// it answers each frame from a script and counts what it was asked.
private final class StubVision: VisionCompleting, @unchecked Sendable {
    let model = "scene-stub"
    var replies: [ChatCompletionReply?]
    private(set) var timeouts: [Int] = []
    /// Advanced by each call, to make a call take time on the test's clock.
    var onCall: (() -> Void)?

    init(replies: [ChatCompletionReply?]) { self.replies = replies }

    func complete(systemPrompt: String, image: ChatCompletionImage, timeoutSeconds: Int) -> ChatCompletionReply? {
        timeouts.append(timeoutSeconds)
        onCall?()
        guard !replies.isEmpty else { return nil }
        return replies.count == 1 ? replies[0] : replies.removeFirst()
    }

    static func reply(_ control: String, tokens: Int = 1000, direction: String? = nil) -> ChatCompletionReply {
        let directionPart = direction.map { #", "direction": "\#($0)""# } ?? ""
        return ChatCompletionReply(
            text: #"{"control": "\#(control)"\#(directionPart), "rationale": "stub"}"#,
            usage: ChatCompletionUsage(promptTokens: tokens - 50, completionTokens: 50, totalTokens: tokens),
            responseModel: "scene-stub-1")
    }
}

final class SceneLoopTests: XCTestCase {

    private let header = SceneHeader(
        name: "reach",
        budget: SceneBudget(maxFrames: 10, maxTokens: 400000, maxSeconds: 180),
        controls: [
            SceneControl(name: "move", gesture: .drag(x: 0.5, y: 0.5, radius: 0.1)),
            SceneControl(name: "fire", gesture: .tap(x: 0.25, y: 0.5)),
        ],
        objective: "Reach GOAL.", success: [.visible("GOAL")], fail: [.visible("DEFAITE")],
        imageWidth: nil, needsDecider: false)

    private func frame(_ texts: String...) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: texts.map { TapPoint(text: $0, tapX: 100, tapY: 100, confidence: 1) },
            screenshotBase64: "aGk=")
    }

    private struct Rig {
        let loop: SceneLoop
        let input: StubInput
        let vision: StubVision
        let describer: StubDescriber
        let clock: Clock
    }

    private final class Clock: @unchecked Sendable {
        var now = 0.0
    }

    private func rig(
        frames: [ScreenDescriber.DescribeResult?], replies: [ChatCompletionReply?],
        windowSize: CGSize = CGSize(width: 400, height: 800)
    ) -> Rig {
        let describer = StubDescriber()
        describer.describeResults = frames
        let input = StubInput()
        let vision = StubVision(replies: replies)
        let bridge = StubBridge()
        bridge.windowInfo = WindowInfo(windowID: 1, position: .zero, size: windowSize, pid: 1)
        let clock = Clock()
        let loop = SceneLoop(dependencies: .init(
            bridge: bridge, describer: describer, input: input, vision: vision,
            now: { clock.now }, sleep: { _ in }, settleMs: 0, imageWidth: 400,
            callTimeoutSeconds: 30))
        return Rig(loop: loop, input: input, vision: vision, describer: describer, clock: clock)
    }

    private func play(_ rig: Rig, budget: SceneBudget? = nil) -> SceneReport {
        rig.loop.run(header: header, budget: budget ?? header.budget, evidence: nil)
    }

    func testTheSuccessPredicatePassesOnTheFrameThatShowsIt() {
        let rig = rig(frames: [frame("F1"), frame("F2"), frame("F3"), frame("GOAL")],
                      replies: [StubVision.reply("fire")])
        let report = play(rig)
        XCTAssertEqual(report.verdict, .pass)
        XCTAssertEqual(report.reason, .success)
        XCTAssertEqual(report.frames, 3)
        XCTAssertEqual(report.framesToPredicate, 3)
        XCTAssertEqual(rig.input.tapCalls.count, 3, "one touch per accepted reply")
        XCTAssertEqual(report.totalTokens, 3000)
        XCTAssertEqual(report.model, "scene-stub")
        XCTAssertEqual(report.responseModel, "scene-stub-1")
    }

    func testTheFailPredicateFailsEvenWhenTheGoalShowsToo() {
        let report = play(rig(frames: [frame("DEFAITE", "GOAL")], replies: [StubVision.reply("fire")]))
        XCTAssertEqual(report.verdict, .fail)
        XCTAssertEqual(report.reason, .fail)
        XCTAssertNil(report.framesToPredicate)
    }

    func testMaxFramesIsInconclusive() {
        let rig = rig(frames: [frame("F")], replies: [StubVision.reply("fire")])
        let report = play(rig, budget: SceneBudget(maxFrames: 3, maxTokens: 400000, maxSeconds: 180))
        XCTAssertEqual(report.verdict, .inconclusive)
        XCTAssertEqual(report.reason, .maxFrames)
        XCTAssertEqual(report.frames, 3)
        XCTAssertEqual(rig.input.tapCalls.count, 3)
    }

    func testTheTokenBudgetStopsBeforeAFrameThatWouldExceedIt() {
        let rig = rig(frames: [frame("F")], replies: [StubVision.reply("fire", tokens: 24050)])
        let report = play(rig, budget: SceneBudget(maxFrames: 10, maxTokens: 50000, maxSeconds: 180))
        XCTAssertEqual(report.reason, .maxTokens)
        XCTAssertEqual(report.frames, 2)
        XCTAssertLessThanOrEqual(report.totalTokens, 50000)
    }

    func testTheTimeBudgetStopsAndBoundsEachCall() {
        let rig = rig(frames: [frame("F")], replies: [StubVision.reply("fire")])
        rig.vision.onCall = { rig.clock.now += 25 }
        let report = play(rig, budget: SceneBudget(maxFrames: 10, maxTokens: 400000, maxSeconds: 60))
        XCTAssertEqual(report.reason, .maxSeconds)
        XCTAssertEqual(report.verdict, .inconclusive)
        XCTAssertEqual(rig.vision.timeouts, [30, 30, 10], "no call may outlast the time left")
    }

    func testACallThatTimesOutAtTheDeadlineIsInconclusive() {
        let rig = rig(frames: [frame("F")], replies: [nil])
        rig.vision.onCall = { rig.clock.now += 60 }
        let report = play(rig, budget: SceneBudget(maxFrames: 10, maxTokens: 400000, maxSeconds: 60))
        XCTAssertEqual(report.reason, .maxSeconds)
        XCTAssertTrue(rig.input.tapCalls.isEmpty)
    }

    func testARejectedReplyTouchesNothingButSpendsTheBudget() {
        let bad = ChatCompletionReply(
            text: "jump!", usage: ChatCompletionUsage(promptTokens: 950, completionTokens: 50, totalTokens: 1000),
            responseModel: nil)
        let rig = rig(frames: [frame("F")], replies: [bad])
        let report = play(rig, budget: SceneBudget(maxFrames: 2, maxTokens: 400000, maxSeconds: 180))
        XCTAssertEqual(report.reason, .maxFrames)
        XCTAssertEqual(report.rejectedReplies, 2)
        XCTAssertEqual(report.totalTokens, 2000)
        XCTAssertTrue(rig.input.tapCalls.isEmpty)
        XCTAssertTrue(rig.input.dragCalls.isEmpty)
    }

    func testAReplyWithoutUsageFailsTheScene() {
        let noUsage = ChatCompletionReply(
            text: #"{"control": "fire", "rationale": "x"}"#, usage: nil, responseModel: nil)
        let rig = rig(frames: [frame("F")], replies: [noUsage])
        let report = play(rig)
        XCTAssertEqual(report.reason, .usageMissing)
        XCTAssertEqual(report.verdict, .fail)
        XCTAssertTrue(rig.input.tapCalls.isEmpty, "a cost the budget cannot count is never acted on")
    }

    func testAnUnreadableFrameFailsTheScene() {
        let unreadable = ScreenDescriber.DescribeResult(
            elements: [], screenshotBase64: "aGk=", ocrFailure: "Vision request failed")
        let report = play(rig(frames: [unreadable], replies: [StubVision.reply("fire")]))
        XCTAssertEqual(report.reason, .perceptionFailed)
        XCTAssertEqual(report.verdict, .fail)
    }

    func testATouchThatCannotBePostedFailsTheScene() {
        let rig = rig(frames: [frame("F")], replies: [StubVision.reply("fire")])
        rig.input.tapResult = "window not found"
        let report = play(rig)
        XCTAssertEqual(report.reason, .inputFailed)
        XCTAssertEqual(report.verdict, .fail)
    }

    func testControlsScaleWithTheWindowAndADragFollowsItsDirection() {
        let rig = rig(frames: [frame("F"), frame("GOAL")], replies: [StubVision.reply("move", direction: "right")],
                      windowSize: CGSize(width: 900, height: 400))
        _ = play(rig)
        let drag = rig.input.dragCalls.first
        XCTAssertEqual(drag?.fromX, 450)
        XCTAssertEqual(drag?.fromY, 200)
        XCTAssertEqual(drag?.toX ?? 0, 490, accuracy: 0.001, "radius 0.1 of the shorter side, to the right")
        XCTAssertEqual(drag?.toY ?? 0, 200, accuracy: 0.001)
    }

    func testTheReportEncodesEveryKeyWithNullsForAbsentValues() throws {
        let report = play(rig(frames: [frame("F")], replies: [nil]),
                          budget: SceneBudget(maxFrames: 1, maxTokens: 400000, maxSeconds: 180))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(report), as: UTF8.self)
        XCTAssertTrue(json.contains(#""frames_to_predicate":null"#), json)
        XCTAssertTrue(json.contains(#""response_model":null"#), json)
        XCTAssertTrue(json.contains(#""verdict":"inconclusive""#), json)
    }
}
