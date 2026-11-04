// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the offer of run_steps when an agent repeats a sequence, and that tools/list loads run_steps up front.
// ABOUTME: The call shapes come from the App Store searches agents ran on the iPhone, one call at a time.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class RepeatedSequenceAdvisorTests: XCTestCase {

    private func tap(_ advisor: RepeatedSequenceAdvisor) -> String? {
        advisor.observe(tool: "tap", arguments: ["x": .number(200), "y": .number(840)], failed: false)
    }
    private func type(_ advisor: RepeatedSequenceAdvisor, _ text: String) -> String? {
        advisor.observe(tool: "type_text", arguments: ["text": .string(text)], failed: false)
    }
    private func returnKey(_ advisor: RepeatedSequenceAdvisor) -> String? {
        advisor.observe(tool: "press_key", arguments: ["key": .string("return")], failed: false)
    }
    private func read(_ advisor: RepeatedSequenceAdvisor) -> String? {
        advisor.observe(tool: "describe_screen", arguments: [:], failed: false)
    }

    func testTheSecondSearchEarnsTheOfferWithItsSteps() {
        let advisor = RepeatedSequenceAdvisor()
        XCTAssertNil(tap(advisor))
        XCTAssertNil(type(advisor, "calculator"))
        XCTAssertNil(returnKey(advisor))
        XCTAssertNil(read(advisor))
        XCTAssertNil(tap(advisor))
        XCTAssertNil(type(advisor, "weather"))
        let advice = returnKey(advisor)
        XCTAssertEqual(advice, "You have now run this sequence twice. To run it again in one call, "
            + "use run_steps with steps like [\"tap: @200,840\", \"type: weather\", "
            + "\"press_key: return\"], changing the values.")
    }

    func testAShapeIsOfferedOnce() {
        let advisor = RepeatedSequenceAdvisor()
        var offers = 0
        for query in ["a", "b", "c", "d", "e", "f"] {
            for advice in [tap(advisor), type(advisor, query), returnKey(advisor)] where advice != nil {
                offers += 1
            }
        }
        XCTAssertEqual(offers, 1)
    }

    func testOneKeyHeldDownIsNotASequence() {
        let advisor = RepeatedSequenceAdvisor()
        for _ in 0 ..< 12 {
            XCTAssertNil(advisor.observe(tool: "press_key", arguments: ["key": .string("delete")], failed: false))
        }
    }

    func testAFailedCallStartsOver() {
        let advisor = RepeatedSequenceAdvisor()
        _ = tap(advisor)
        _ = type(advisor, "a")
        _ = advisor.observe(tool: "tap", arguments: ["text": .string("x")], failed: true)
        _ = tap(advisor)
        XCTAssertNil(type(advisor, "b"), "only one full run since the failure")
    }

    func testAnInputToolWithNoStepFormStartsOver() {
        let advisor = RepeatedSequenceAdvisor()
        _ = tap(advisor)
        _ = type(advisor, "a")
        _ = advisor.observe(tool: "pinch", arguments: [:], failed: false)
        _ = tap(advisor)
        XCTAssertNil(type(advisor, "b"))
    }

    func testModifiersAreWrittenInTheStepGrammar() throws {
        let advisor = RepeatedSequenceAdvisor()
        let selectAll: [String: JSONValue] = ["key": .string("a"), "modifiers": .array([.string("command")])]
        _ = advisor.observe(tool: "press_key", arguments: selectAll, failed: false)
        _ = type(advisor, "x")
        _ = advisor.observe(tool: "press_key", arguments: selectAll, failed: false)
        let advice = try XCTUnwrap(type(advisor, "y"))
        XCTAssertTrue(advice.contains("press_key: a modifiers: [\"command\"]"), advice)
        guard case .pressKey(let key, let modifiers)? =
            SkillParser.parseStep("press_key: a modifiers: [\"command\"]") else {
            return XCTFail("the offered step must parse")
        }
        XCTAssertEqual(key, "a")
        XCTAssertEqual(modifiers, ["command"])
    }

    // MARK: - Through the server

    private func server(policy: PermissionPolicy) -> MCPServer {
        let server = MCPServer(policy: policy)
        for name in ["tap", "type_text", "run_steps"] {
            server.registerTool(MCPToolDefinition(
                name: name, description: name, inputSchema: ["type": .string("object")],
                handler: { _ in .text("ok") }))
        }
        return server
    }

    private func call(_ server: MCPServer, _ tool: String, _ args: [String: JSONValue]) -> [JSONValue] {
        let request = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "tools/call",
                                     params: .object(["name": .string(tool), "arguments": .object(args)]))
        guard case .object(let result)? = server.handleRequest(request)?.result,
              case .array(let content)? = result["content"] else { return [] }
        return content
    }

    func testTheOfferArrivesAsAnExtraBlockInTheReply() {
        let server = server(policy: PermissionPolicy(skipPermissions: true, config: nil))
        let tapArgs: [String: JSONValue] = ["text": .string("Search")]
        XCTAssertEqual(call(server, "tap", tapArgs).count, 1)
        XCTAssertEqual(call(server, "type_text", ["text": .string("a")]).count, 1)
        XCTAssertEqual(call(server, "tap", tapArgs).count, 1)
        XCTAssertEqual(call(server, "type_text", ["text": .string("b")]).count, 2)
    }

    func testNoOfferWhenRunStepsIsNotAllowed() {
        let policy = PermissionPolicy(skipPermissions: false,
                                      config: PermissionConfig(allow: ["tap", "type_text"]))
        let server = server(policy: policy)
        for text in ["a", "b", "c"] {
            XCTAssertEqual(call(server, "tap", [:]).count, 1)
            XCTAssertEqual(call(server, "type_text", ["text": .string(text)]).count, 1)
        }
    }

    func testToolsListAsksClientsToLoadRunStepsUpFront() {
        let server = server(policy: PermissionPolicy(skipPermissions: true, config: nil))
        let request = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "tools/list", params: nil)
        guard case .object(let result)? = server.handleRequest(request)?.result,
              case .array(let tools)? = result["tools"] else { return XCTFail("no tools") }
        var meta: [String: JSONValue?] = [:]
        for case .object(let tool) in tools {
            if case .string(let name)? = tool["name"] { meta[name] = tool["_meta"] }
        }
        XCTAssertEqual(meta["run_steps"], .object(["anthropic/alwaysLoad": .bool(true)]))
        XCTAssertEqual(meta["tap"], .some(nil), "other tools stay deferred")
    }
}
