// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests how a scene is read: the kind:game skill's header, the scene: step line, and the model's reply.
// ABOUTME: Each refusal mirrors mirroir-skills' validator, so a scene that would play wrong never starts.

import XCTest
@testable import mirroir_mcp

final class SceneParsingTests: XCTestCase {

    static let scene = """
        ---
        version: 1
        name: Scene Frames Reach
        kind: game
        surface: scene
        playable: single-control
        controls: [move, fire]
        budget: { max_frames: 10, max_tokens: 400000, max_seconds: 180 }
        success: { visible: "GOAL" }
        fail: { visible: "DÉFAITE, encore" }
        ---

        A fixture.

        ## Objective

        Reach the screen that says GOAL.

        ## Controls

        - move: drag from 0.18,0.80 radius 0.08
        - fire: tap at 0.683,0.58
        """

    // MARK: - Header

    func testAWellFormedSceneSkillParses() throws {
        let header = try SceneHeaderParser.parse(content: Self.scene, name: "reach").get()
        XCTAssertEqual(header.budget, SceneBudget(maxFrames: 10, maxTokens: 400000, maxSeconds: 180))
        XCTAssertEqual(header.success, .visible("GOAL"))
        XCTAssertEqual(header.fail, .visible("DÉFAITE, encore"), "a comma inside quotes stays in the value")
        XCTAssertEqual(header.objective, "Reach the screen that says GOAL.")
        XCTAssertEqual(header.controls, [
            SceneControl(name: "move", gesture: .drag(x: 0.18, y: 0.80, radius: 0.08)),
            SceneControl(name: "fire", gesture: .tap(x: 0.683, y: 0.58)),
        ])
    }

    private func refusal(_ content: String) -> SceneHeaderError? {
        if case .failure(let error) = SceneHeaderParser.parse(content: content, name: "x") { return error }
        return nil
    }

    func testAnOrdinarySkillIsNotAScene() {
        XCTAssertEqual(refusal(Self.scene.replacingOccurrences(of: "kind: game\n", with: "")), .notAGame)
    }

    func testAnObserveOnlySceneIsRefused() {
        XCTAssertEqual(refusal(Self.scene.replacingOccurrences(
            of: "playable: single-control", with: "playable: observe-only")), .observeOnly)
    }

    func testAMissingSuccessPredicateIsRefused() {
        XCTAssertEqual(refusal(Self.scene.replacingOccurrences(of: "success: { visible: \"GOAL\" }\n", with: "")),
                       .predicate(field: "success", reason: "missing"))
    }

    func testAnUnknownPredicateIsRefused() {
        XCTAssertEqual(refusal(Self.scene.replacingOccurrences(of: "visible: \"GOAL\"", with: "score: \"9\"")),
                       .predicate(field: "success", reason: "unknown predicate 'score'"))
    }

    func testAnUntypedBudgetIsRefused() {
        let error = refusal(Self.scene.replacingOccurrences(of: "max_seconds: 180", with: "max_minutes: 3"))
        XCTAssertEqual(error, .budget(
            "unknown field 'max_minutes' (expected max_frames, max_tokens, max_seconds)"))
    }

    func testAPinchControlIsRefused() {
        guard case .controls = refusal(Self.scene.replacingOccurrences(
            of: "fire: tap at", with: "fire: pinch at")) else { return XCTFail("pinch accepted") }
    }

    func testAControlOutsideTheWindowIsRefused() {
        guard case .controls(let reason) = refusal(Self.scene.replacingOccurrences(
            of: "0.683,0.58", with: "683,580")) else { return XCTFail("pixel point accepted") }
        XCTAssertTrue(reason.contains("window fraction"), reason)
    }

    func testAControlWithoutACalibrationIsRefused() {
        XCTAssertEqual(refusal(Self.scene.replacingOccurrences(of: "- fire: tap at 0.683,0.58", with: "")),
                       .controls("'fire' has no line in ## Controls"))
    }

    func testASimultaneousControlIsRefused() {
        guard case .controls = refusal(Self.scene.replacingOccurrences(
            of: "- move: drag", with: "- move+aim: drag")) else { return XCTFail("two controls accepted") }
    }

    func testASceneWithoutAnObjectiveIsRefused() {
        XCTAssertEqual(refusal(Self.scene.replacingOccurrences(
            of: "## Objective\n\nReach the screen that says GOAL.\n\n", with: "")), .noObjective)
    }

    // MARK: - Step line

    func testTheSceneStepLineParses() {
        let step = SkillParser.parseStep(
            key: "scene",
            rawValue: #"{ skill: "scene-frames-reach", max_frames: 6, max_tokens: 150000, max_seconds: 60 }"#)
        guard case .scene(let skill, let budget) = step else { return XCTFail("\(step)") }
        XCTAssertEqual(skill, "scene-frames-reach")
        XCTAssertEqual(budget, SceneBudget(maxFrames: 6, maxTokens: 150000, maxSeconds: 60))
        XCTAssertEqual(step.typeKey, "scene")
        XCTAssertNil(step.replayValue, "a scene is never compiled, so it has nothing to replay")
    }

    func testABudgetKeyTypoIsInvalid() {
        let step = SkillParser.parseStep(
            key: "scene",
            rawValue: "{ skill: x, max_frames: 6, max_touches: 3, max_tokens: 9, max_seconds: 9 }")
        guard case .invalid(_, let reason) = step else { return XCTFail("\(step)") }
        XCTAssertTrue(reason.contains("max_touches"), reason)
    }

    func testAMissingOrZeroBudgetFieldIsInvalid() {
        for raw in ["{ skill: x, max_frames: 6, max_tokens: 9 }",
                    "{ skill: x, max_frames: 0, max_tokens: 9, max_seconds: 9 }",
                    "{ max_frames: 6, max_tokens: 9, max_seconds: 9 }"] {
            guard case .invalid = SkillParser.parseStep(key: "scene", rawValue: raw) else {
                return XCTFail("accepted \(raw)")
            }
        }
    }

    func testANarrowerStepBudgetFitsAndAWiderOneDoesNot() {
        let skill = SceneBudget(maxFrames: 10, maxTokens: 400000, maxSeconds: 180)
        XCTAssertEqual(SceneBudget(maxFrames: 6, maxTokens: 150000, maxSeconds: 60).fieldsExceeding(skill), [])
        XCTAssertEqual(SceneBudget(maxFrames: 12, maxTokens: 150000, maxSeconds: 600).fieldsExceeding(skill),
                       ["max_frames", "max_seconds"])
    }

    // MARK: - Reply

    private var controls: [SceneControl] {
        (try? SceneHeaderParser.parse(content: Self.scene, name: "x").get().controls) ?? []
    }

    func testAReplyNamingATapControlIsOneAction() {
        let action = ScenePrompt.parseAction(
            #"{"control": "fire", "rationale": "an enemy ahead"}"#, controls: controls)
        XCTAssertEqual(action?.control.name, "fire")
        XCTAssertNil(action?.direction)
    }

    func testADragReplyNeedsADirectionAndAFenceIsAccepted() {
        let fenced = "```json\n{\"control\": \"move\", \"direction\": \"up-left\", \"rationale\": \"cover\"}\n```"
        XCTAssertEqual(ScenePrompt.parseAction(fenced, controls: controls)?.direction, .upLeft)
        XCTAssertNil(ScenePrompt.parseAction(
            #"{"control": "move", "rationale": "go"}"#, controls: controls), "a drag with no direction")
    }

    func testAnythingButOneAllowedControlIsRejected() {
        for reply in [
            #"{"control": "jump", "rationale": "x"}"#,
            #"{"control": "fire", "direction": "up", "rationale": "x"}"#,
            #"{"control": "fire", "rationale": "x", "x": 10, "y": 20}"#,
            "fire",
            #"{"control": "fire", "rationale": "x"} and then move"#,
        ] {
            XCTAssertNil(ScenePrompt.parseAction(reply, controls: controls), reply)
        }
    }

    func testThePromptNamesTheObjectiveAndEveryControl() throws {
        let header = try SceneHeaderParser.parse(content: Self.scene, name: "x").get()
        let prompt = ScenePrompt.systemPrompt(for: header)
        XCTAssertTrue(prompt.contains("Reach the screen that says GOAL."))
        XCTAssertTrue(prompt.contains("- move: a drag"))
        XCTAssertTrue(prompt.contains("- fire: a tap"))
    }
}
