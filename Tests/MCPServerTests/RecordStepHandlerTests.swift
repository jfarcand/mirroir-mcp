// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the record_step MCP handler: unrebuildable steps, and icon taps replay could not check.
// ABOUTME: A SKILL.md replays from its recorded steps, so an unreadable record would fail only at replay time.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class RecordStepHandlerTests: XCTestCase {

    private var server: MCPServer!
    private var describer: StubDescriber!
    private var session: CompilationSession!

    override func setUp() {
        super.setUp()
        server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil))
        describer = StubDescriber()
        session = CompilationSession()
        let context = TargetContext(
            name: "iphone", targetType: "iphone-mirroring", bundleID: nil,
            bridge: StubBridge(), input: StubInput(),
            capture: StubCapture(), describer: describer, recorder: StubRecorder(),
            capabilities: [])
        let registry = TargetRegistry(targets: ["iphone": context], defaultName: "iphone")
        MirroirMCP.registerCompilationTools(
            server: server, registry: registry, session: session)
    }

    private func recordStep(_ args: [String: JSONValue]) -> (isError: Bool, text: String) {
        call("record_step", args)
    }

    private func call(_ tool: String, _ args: [String: JSONValue]) -> (isError: Bool, text: String) {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string(tool), "arguments": .object(args)]))
        guard let response = server.handleRequest(request),
              case .object(let result) = response.result,
              case .array(let content) = result["content"],
              case .object(let textObj) = content.first,
              case .string(let text) = textObj["text"] else {
            return (true, "no response")
        }
        if case .bool(let isError) = result["isError"] {
            return (isError, text)
        }
        return (false, text)
    }

    func testToolOnlyStepIsRecordedWithANoteThatTheRunnerCannotReplayIt() {
        let result = recordStep(["step_index": .number(8), "type": .string("press_back")])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("cannot replay"), result.text)
        XCTAssertTrue(MirroirMCP.skillMdReplayProblems([
            CompiledStep(index: 0, type: "press_back", label: nil, hints: nil),
        ]).isEmpty, "a save is not blocked: re-recording cannot change the step")
    }

    func testTargetLabelMustBeTheSelectorMap() {
        let unreadable = recordStep([
            "step_index": .number(0), "type": .string("target"), "label": .string("Notes"),
        ])
        XCTAssertTrue(unreadable.text.contains("cannot replay"), unreadable.text)

        let accepted = recordStep([
            "step_index": .number(0), "type": .string("target"),
            "label": .string("{ kind: ios, app: \"Notes\" }"),
        ])
        XCTAssertFalse(accepted.isError, accepted.text)
        XCTAssertTrue(accepted.text.contains("passthrough"))
        XCTAssertFalse(accepted.text.contains("cannot replay"), accepted.text)
    }

    func testAliasIsStoredAsTheCanonicalStepWithHints() {
        let result = recordStep(["step_index": .number(0), "type": .string("press_home")])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Recorded step 0: home"), result.text)
        XCTAssertTrue(result.text.contains("passthrough"), result.text)
    }

    func testSkillMdChecksRefuseStepsThatCannotReplay() {
        func problems(_ type: String, _ label: String?) -> [String] {
            MirroirMCP.skillMdReplayProblems([
                CompiledStep(index: 0, type: type, label: label, hints: .passthrough()),
            ])
        }
        XCTAssertFalse(problems("measure", "login_time").isEmpty)
        XCTAssertFalse(problems("measure", "{ tap: \"Login\", name: \"t\" }").isEmpty)
        XCTAssertFalse(problems("measure", "{ tap: \"\", until: \"Home\" }").isEmpty)
        XCTAssertTrue(problems("drag", "Photo").first?.contains("from/to") == true)
        XCTAssertTrue(problems("drag", "{ to: \"Trash\" }").first?.contains("both ends") == true)
        XCTAssertFalse(problems("tap", nil).isEmpty)
        XCTAssertTrue(problems("measure", "{ tap: \"Login\", until: \"Dashboard\" }").isEmpty)
        XCTAssertTrue(problems("remember", "the order number").isEmpty)
        XCTAssertTrue(problems("home", nil).isEmpty)
        // A tap recorded by coordinates alone replays from its hint without a label.
        XCTAssertTrue(MirroirMCP.skillMdReplayProblems([
            CompiledStep(index: 0, type: "tap", label: nil,
                         hints: .tap(x: 40, y: 880, strategy: "unknown")),
        ]).isEmpty)
        // A malformed selector can be recorded again; a tool with no step type cannot.
        XCTAssertFalse(problems("switch_target", "Notes").isEmpty)
        XCTAssertTrue(problems("press_back", nil).isEmpty)
    }

    func testACoordinateOnlyTapRecordsTheScreenItLedTo() {
        startOn(["Alarmes", "Aucune alarme", "Horloges"])
        describer.describeResult = screen(["General", "Privacy", "Battery"])
        let result = recordStep([
            "step_index": .number(0), "type": .string("tap"),
            "tap_x": .number(120), "tap_y": .number(300),
        ])
        XCTAssertFalse(result.isError, result.text)
        let recorded = session.recordedSteps.first?.hints?.arrivalFingerprint
        XCTAssertEqual(recorded?.structuralTexts.isEmpty, false,
                       "replay compares the screen it reaches against this one")
    }

    private func screen(_ texts: [String]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: texts.enumerated().map { index, text in
                TapPoint(text: text, tapX: 100, tapY: Double(200 + 60 * index), confidence: 0.9)
            },
            screenshotBase64: "")
    }

    /// The start screen get_skill reads before step 0.
    private func startOn(_ texts: [String]) {
        let start = screen(texts)
        session.markStart(skillPath: "skill.md") {
            StructuralFingerprint.buildScreenFingerprint(elements: start.elements, icons: [])
        }
    }

    private func recordIconTap(_ index: Int) -> (isError: Bool, text: String) {
        recordStep([
            "step_index": .number(Double(index)), "type": .string("tap"),
            "tap_x": .number(120), "tap_y": .number(300),
        ])
    }

    func testACoordinateOnlyTapToABareScreenIsRefused() {
        describer.describeResult = screen(["OK"])
        let result = recordIconTap(0)
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("readable labels"), result.text)
        XCTAssertTrue(session.recordedSteps.isEmpty)
    }

    func testACoordinateOnlyTapCannotBeReRecordedAfterALaterStep() {
        startOn(["Alarmes", "Aucune alarme", "Horloges"])
        describer.describeResult = screen(["General", "Privacy", "Battery"])
        XCTAssertFalse(recordIconTap(0).isError)
        XCTAssertFalse(recordStep(["step_index": .number(1), "type": .string("home")]).isError)
        let result = recordIconTap(0)
        XCTAssertTrue(result.isError, "the screen now is not the one tap 0 led to")
        XCTAssertTrue(result.text.contains("Step 1 is already recorded"), result.text)
    }

    func testACoordinateOnlyTapThatChangedNothingIsRefused() {
        // The tap was dropped: the screen after it is the start screen.
        startOn(["Alarmes", "Aucune alarme", "Horloges"])
        describer.describeResult = screen(["Alarmes", "Aucune alarme", "Horloges"])
        let result = recordIconTap(0)
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("did not change the screen"), result.text)
        XCTAssertTrue(session.recordedSteps.isEmpty, "replay could never prove this tap")
    }

    func testACoordinateOnlyTapIsComparedWithTheScreenTheStepBeforeLeft() {
        startOn(["Chronomètre", "Démarrer", "Horloges"])
        describer.describeResult = screen(["Alarmes", "Aucune alarme", "Horloges"])
        XCTAssertFalse(recordStep([
            "step_index": .number(0), "type": .string("wait_for"),
            "label": .string("Aucune alarme"),
        ]).isError)

        let unchanged = recordIconTap(1)
        XCTAssertTrue(unchanged.text.contains("did not change the screen"), unchanged.text)

        describer.describeResult = screen(["Annuler", "Enregistrer", "Nouv. alarme", "Sonnerie"])
        let changed = recordIconTap(1)
        XCTAssertFalse(changed.isError, changed.text)
        XCTAssertNotNil(session.recordedSteps.last?.hints?.arrivalFingerprint)
    }

    func testACoordinateOnlyTapWithNoScreenBeforeItIsRefused() {
        describer.describeResult = screen(["General", "Privacy", "Battery"])
        let first = recordIconTap(0)
        XCTAssertTrue(first.isError, first.text)
        XCTAssertTrue(first.text.contains("Call get_skill before the first step"), first.text)

        startOn(["Alarmes", "Aucune alarme", "Horloges"])
        describer.describeResult = nil
        XCTAssertFalse(recordStep(["step_index": .number(0), "type": .string("home")]).isError,
                       "an unreadable screen does not block a step that needs no check")
        describer.describeResult = screen(["General", "Privacy", "Battery"])
        let next = recordIconTap(1)
        XCTAssertTrue(next.isError, next.text)
        XCTAssertTrue(next.text.contains("after step 0 was not read"), next.text)
    }

    func testACoordinateOnlyTapIsRefusedWhenItsScreenCannotBeRead() {
        describer.describeResult = nil
        let result = recordStep([
            "step_index": .number(0), "type": .string("tap"),
            "tap_x": .number(120), "tap_y": .number(300),
        ])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(session.recordedSteps.isEmpty, "a tap replay could not check is not recorded")
    }

    func testMeasureWithAnUnreadableActionGetsTheRunnerNote() {
        let result = recordStep([
            "step_index": .number(0), "type": .string("measure"),
            "label": .string("{ wiat_for: \"Home\", until: \"Dashboard\" }"),
        ])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("wiat_for"), result.text)
    }

    func testSaveRefusesAGapInRecordedIndices() {
        _ = recordStep(["step_index": .number(0), "type": .string("home")])
        _ = recordStep(["step_index": .number(2), "type": .string("shake")])

        let result = call("save_compiled", ["skill_name": .string("anything")])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("index 1"), result.text)
    }

    func testNegativeStepIndexIsRefused() {
        let result = recordStep(["step_index": .number(-1), "type": .string("home")])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("0 or more"), result.text)
    }

    func testAIOnlyStepIsRecordedWithoutHints() {
        let result = recordStep([
            "step_index": .number(2), "type": .string("remember"),
            "label": .string("the order number"),
        ])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("AI-only"))
    }
}
