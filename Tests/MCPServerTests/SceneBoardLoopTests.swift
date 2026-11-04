// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests SceneLoop on a board: cells tapped in order, waits, and a move picker choosing from the model's reading.
// ABOUTME: The model and the picker are documented stubs; CommandSceneDecider itself is tested with real programs.

import CoreGraphics
import HelperLib
import XCTest
@testable import mirroir_mcp

/// Stands in for the paid, non-deterministic vision model: one fixed reply.
private struct ReadingVision: VisionCompleting {
    let model = "scene-stub"
    let text: String

    func complete(systemPrompt: String, image: ChatCompletionImage, timeoutSeconds: Int) -> ChatCompletionReply? {
        ChatCompletionReply(
            text: text, usage: ChatCompletionUsage(promptTokens: 400, completionTokens: 100, totalTokens: 500),
            responseModel: model)
    }
}

/// Stands in for the user's move picker: answers from a script and keeps what it was sent.
private final class ScriptedDecider: SceneDeciding, @unchecked Sendable {
    let command = "stub-picker"
    var outcomes: [SceneDecisionOutcome]
    private(set) var inputs: [[String: Any]] = []

    init(_ outcomes: [SceneDecisionOutcome]) { self.outcomes = outcomes }

    func decide(input: Data, timeoutSeconds: Int) -> SceneDecisionOutcome {
        inputs.append((try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:])
        return outcomes.count == 1 ? outcomes[0] : outcomes.removeFirst()
    }
}

final class SceneBoardLoopTests: XCTestCase {

    private func header(needsDecider: Bool) -> SceneHeader {
        SceneHeader(
            name: "board",
            budget: SceneBudget(maxFrames: 5, maxTokens: 400000, maxSeconds: 600),
            controls: [SceneControl(name: "board", gesture: .grid(cols: 2, rows: 2, x0: 0, y0: 0, x1: 1, y1: 1))],
            objective: "Read the board.", success: [.visible("GOAL")], fail: [.visible("DEFAITE"), .visible("MENU")],
            imageWidth: 800, needsDecider: needsDecider)
    }

    private func frame(_ texts: String...) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: texts.map { TapPoint(text: $0, tapX: 1, tapY: 1, confidence: 1) }, screenshotBase64: "aGk=")
    }

    private func play(
        _ header: SceneHeader, frames: [ScreenDescriber.DescribeResult?], reply: String,
        decider: (any SceneDeciding)? = nil, input: StubInput = StubInput()
    ) -> SceneReport {
        let describer = StubDescriber()
        describer.describeResults = frames
        let bridge = StubBridge()
        bridge.windowInfo = WindowInfo(windowID: 1, position: .zero, size: CGSize(width: 400, height: 400), pid: 1)
        let loop = SceneLoop(dependencies: .init(
            bridge: bridge, describer: describer, input: input, vision: ReadingVision(text: reply),
            now: { 0 }, sleep: { _ in }, settleMs: 0, imageWidth: 400, callTimeoutSeconds: 30,
            decider: decider, cellTapGapMs: 0))
        return loop.run(header: header, budget: header.budget, evidence: nil)
    }

    func testTheModelsCellsAreTappedInOrderAtTheirCenters() {
        let input = StubInput()
        let report = play(
            header(needsDecider: false), frames: [frame("F"), frame("GOAL")],
            reply: #"{"control": "board", "cells": ["a1", "b2"], "rationale": "x"}"#, input: input)
        XCTAssertEqual(report.verdict, .pass)
        XCTAssertEqual(input.tapCalls.map(\.x), [100, 300], "a is the left column, b the right")
        XCTAssertEqual(input.tapCalls.map(\.y), [300, 100], "row 1 is the bottom, row 2 the top")
    }

    func testAnyFailTextStopsTheScene() {
        let report = play(header(needsDecider: false), frames: [frame("MENU")],
                          reply: #"{"control": "none", "rationale": "x"}"#)
        XCTAssertEqual(report.reason, .fail)
    }

    func testAWaitTouchesNothingAndIsCounted() {
        let input = StubInput()
        let report = play(header(needsDecider: false), frames: [frame("F")],
                          reply: #"{"control": "none", "rationale": "the bot is thinking"}"#, input: input)
        XCTAssertEqual(report.reason, .maxFrames)
        XCTAssertEqual(report.waits, 5)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    func testTheMovePickerChoosesFromTheModelsReading() throws {
        let decider = ScriptedDecider([.answered(#"{"control": "board", "cells": ["a2", "b1"]}"#)])
        let input = StubInput()
        let report = play(
            header(needsDecider: true), frames: [frame("F", "e4"), frame("GOAL")],
            reply: #"{"reading": "8/8 w", "rationale": "board read"}"#, decider: decider, input: input)
        XCTAssertEqual(report.verdict, .pass)
        XCTAssertEqual(report.deciderCalls, 1)
        XCTAssertEqual(input.tapCalls.count, 2)
        let sent = try XCTUnwrap(decider.inputs.first)
        XCTAssertEqual(sent["reading"] as? String, "8/8 w")
        XCTAssertEqual(sent["frame"] as? Int, 1)
        XCTAssertEqual(sent["ocr"] as? [String], ["F", "e4"])
        XCTAssertFalse((sent["run_id"] as? String ?? "").isEmpty)
        let controls = try XCTUnwrap(sent["controls"] as? [[String: Any]])
        XCTAssertEqual(controls.first?["kind"] as? String, "grid")
        XCTAssertEqual(controls.first?["cols"] as? Int, 2)
    }

    func testTheRunIDStaysTheSameAcrossFrames() {
        let decider = ScriptedDecider([.answered(#"{"control": "none"}"#)])
        let report = play(header(needsDecider: true), frames: [frame("F")],
                          reply: #"{"reading": "r", "rationale": "x"}"#, decider: decider)
        XCTAssertEqual(report.waits, 5)
        XCTAssertEqual(Set(decider.inputs.compactMap { $0["run_id"] as? String }).count, 1)
        XCTAssertEqual(decider.inputs.compactMap { $0["frame"] as? Int }, [1, 2, 3, 4, 5])
    }

    func testABrokenMovePickerFailsTheScene() {
        for outcome in [SceneDecisionOutcome.failed("exit 1"), .timedOut,
                        .answered(#"{"control": "board", "cells": ["z9"]}"#), .answered("bestmove e2e4")] {
            let report = play(header(needsDecider: true), frames: [frame("F")],
                              reply: #"{"reading": "r", "rationale": "x"}"#, decider: ScriptedDecider([outcome]))
            XCTAssertEqual(report.reason, .deciderFailed, "\(outcome)")
            XCTAssertEqual(report.verdict, .fail)
        }
    }

    func testAModelReplyThatIsNotAReadingIsRejectedNotPassedOn() {
        let decider = ScriptedDecider([.answered(#"{"control": "none"}"#)])
        let report = play(header(needsDecider: true), frames: [frame("F")],
                          reply: #"{"control": "board", "cells": ["a1"], "rationale": "x"}"#, decider: decider)
        XCTAssertEqual(report.rejectedReplies, 5)
        XCTAssertEqual(report.deciderCalls, 0)
    }

    func testOneDroppedCaptureIsReadAgainNotAFailure() {
        let unreadable = ScreenDescriber.DescribeResult(
            elements: [], screenshotBase64: "aGk=", ocrFailure: "capture dropped")
        let report = play(
            header(needsDecider: false), frames: [frame("F"), unreadable, frame("GOAL")],
            reply: #"{"control": "none", "rationale": "x"}"#)
        XCTAssertEqual(report.verdict, .pass, "the second read of frame 2 shows GOAL")
    }

    // MARK: - The command itself

    private func script(_ body: String) throws -> String {
        let path = NSTemporaryDirectory() + "picker-\(UUID().uuidString).sh"
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testACommandGetsTheInputOnStdinAndItsArguments() throws {
        let path = try script(#"read line; echo "$1|$line""#)
        let decider = try XCTUnwrap(CommandSceneDecider(command: "\(path) depth"))
        XCTAssertTrue(decider.isRunnable())
        XCTAssertEqual(decider.decide(input: Data(#"{"frame":1}"#.utf8) + Data("\n".utf8), timeoutSeconds: 5),
                       .answered("depth|{\"frame\":1}\n"))
    }

    func testACommandThatFailsOrHangsIsReported() throws {
        let failing = try XCTUnwrap(CommandSceneDecider(command: try script("cat >/dev/null; echo no >&2; exit 3")))
        guard case .failed(let why) = failing.decide(input: Data("{}".utf8), timeoutSeconds: 5) else {
            return XCTFail("a failing picker answered")
        }
        XCTAssertTrue(why.contains("exited 3"), why)
        let hanging = try XCTUnwrap(CommandSceneDecider(command: try script("sleep 30")))
        XCTAssertEqual(hanging.decide(input: Data("{}".utf8), timeoutSeconds: 1), .timedOut)
    }

    func testOnlyAProgramThatExistsIsRunnable() {
        XCTAssertNil(CommandSceneDecider(command: "   "))
        XCTAssertEqual(CommandSceneDecider(command: "/no/such/picker")?.isRunnable(), false)
        XCTAssertEqual(CommandSceneDecider(command: "sh -c true")?.isRunnable(path: "/bin:/usr/bin"), true)
        XCTAssertEqual(CommandSceneDecider(command: "no-such-picker-xyz")?.isRunnable(path: "/bin"), false)
    }
}
