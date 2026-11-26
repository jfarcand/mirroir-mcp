/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Tests for `expect` on tap, swipe and press_key (carnet#96): the text an action must lead to.
// ABOUTME: A met expectation passes, an unmet one fails the call, a bad argument is refused before acting.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ActionExpectationTests: XCTestCase {

    private var server: MCPServer!
    private var input: StubInput!
    private var describer: StubDescriber!

    override func setUp() {
        super.setUp()
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        server = MCPServer(policy: policy, transport: .stdio)
        input = StubInput()
        describer = StubDescriber()
        let registry = makeTestRegistry(
            bridge: StubBridge(), input: input, describer: describer, ocrDescriber: describer)
        MirroirMCP.registerInputTools(server: server, registry: registry, policy: policy)
        MirroirMCP.registerTapTools(server: server, registry: registry, policy: policy)
    }

    private func screen(_ texts: String...) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: texts.enumerated().map { index, text in
                TapPoint(text: text, tapX: 200, tapY: Double(300 + 60 * index), confidence: 0.95)
            },
            screenshotBase64: "")
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> (text: String, isError: Bool) {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string(name), "arguments": .object(args)]))
        guard let response = server.handleRequest(request),
              case .object(let result) = response.result,
              case .array(let content) = result["content"],
              case .object(let first) = content.first,
              case .string(let text) = first["text"] else { return ("", false) }
        if case .bool(let isError) = result["isError"] { return (text, isError) }
        return (text, false)
    }

    func testAPointTapWhoseExpectationShowsPasses() {
        describer.describeResult = screen("Timers", "Start")
        let reply = call("tap", ["x": .number(100), "y": .number(200), "expect": .string("Start")])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.hasPrefix("Tapped at (100, 200)"), reply.text)
        XCTAssertTrue(reply.text.contains("Expected after it:\n1. PASS wait_for: \"Start\""), reply.text)
        XCTAssertEqual(reply.text.components(separatedBy: "Screen now:").count, 2,
                       "the screen is reported once, after the check: \(reply.text)")
        XCTAssertEqual(input.tapCalls.count, 1)
    }

    func testAPointTapWhoseExpectationNeverShowsFailsTheCall() {
        describer.describeResult = screen("Alarms")
        let reply = call("tap", ["x": .number(100), "y": .number(200),
                                 "expect": .string("Start"), "expect_timeout": .number(1)])
        XCTAssertTrue(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains("Expected after it:\n1. FAIL wait_for: \"Start\""), reply.text)
        XCTAssertEqual(input.tapCalls.count, 1, "the tap was sent; only its outcome failed")
    }

    func testATextTapChecksItsExpectationAsTheNextStep() {
        describer.describeResult = screen("Timers", "Start")
        let reply = call("tap", ["text": .string("Timers"), "expect": .string("Start")])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains("1. PASS tap: \"Timers\""), reply.text)
        XCTAssertTrue(reply.text.contains("2. PASS wait_for: \"Start\""), reply.text)
    }

    func testASwipeWhoseExpectationNeverShowsFailsTheCall() {
        describer.describeResult = screen("Row 1")
        let reply = call("swipe", ["from_x": .number(200), "from_y": .number(600),
                                   "to_x": .number(200), "to_y": .number(300),
                                   "expect": .string("Row 40"), "expect_timeout": .number(1)])
        XCTAssertTrue(reply.isError, reply.text)
        XCTAssertTrue(reply.text.hasPrefix("Swiped from (200,600) to (200,300)"), reply.text)
        XCTAssertEqual(input.swipeCalls.count, 1)
    }

    func testAKeyWhoseExpectationShowsPasses() {
        describer.describeResult = screen("Results")
        let reply = call("press_key", ["key": .string("return"), "expect": .string("Results")])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.hasPrefix("Pressed return"), reply.text)
    }

    func testABadExpectationIsRefusedBeforeTheActionIsSent() {
        let empty = call("tap", ["x": .number(1), "y": .number(1), "expect": .string("  ")])
        XCTAssertTrue(empty.isError)
        XCTAssertEqual(empty.text, "expect must be the text to wait for, not empty")
        let alone = call("swipe", ["from_x": .number(1), "from_y": .number(1), "to_x": .number(1),
                                   "to_y": .number(9), "expect_timeout": .number(3)])
        XCTAssertEqual(alone.text, "expect_timeout applies only with expect")
        let zero = call("press_key", ["key": .string("a"), "expect": .string("A"),
                                      "expect_timeout": .number(0)])
        XCTAssertEqual(zero.text, "expect_timeout must be a whole number of seconds, at least 1")
        XCTAssertTrue(input.tapCalls.isEmpty)
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }
}
