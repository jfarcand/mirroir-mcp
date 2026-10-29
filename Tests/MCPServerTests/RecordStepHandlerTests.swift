// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the record_step MCP handler: it refuses a type and label the skill parser cannot rebuild.
// ABOUTME: A SKILL.md replays from its recorded steps, so an unreadable record would fail only at replay time.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class RecordStepHandlerTests: XCTestCase {

    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil))
        let context = TargetContext(
            name: "iphone", targetType: "iphone-mirroring", bundleID: nil,
            bridge: StubBridge(), input: StubInput(),
            capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder(),
            capabilities: [])
        let registry = TargetRegistry(targets: ["iphone": context], defaultName: "iphone")
        MirroirMCP.registerCompilationTools(
            server: server, registry: registry, session: CompilationSession())
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
                         hints: .tap(x: 40, y: 880, confidence: 0, strategy: "unknown")),
        ]).isEmpty)
        // A malformed selector can be recorded again; a tool with no step type cannot.
        XCTAssertFalse(problems("switch_target", "Notes").isEmpty)
        XCTAssertTrue(problems("press_back", nil).isEmpty)
    }

    func testYamlSessionsStillRecordAStepWithoutALabel() {
        let result = recordStep([
            "step_index": .number(0), "type": .string("tap"),
            "tap_x": .number(120), "tap_y": .number(300),
        ])
        XCTAssertFalse(result.isError, result.text)
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
