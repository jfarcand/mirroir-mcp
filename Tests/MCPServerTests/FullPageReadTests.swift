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
// ABOUTME: Tests for describe_screen's full-page read: why the scrolling stopped, its scroll budget and the point it scrolls at.
// ABOUTME: Drives CalibrationScroller with stub input and reads, and the describe_screen tool through the MCP server.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class FullPageReadTests: XCTestCase {

    private var bridge: StubBridge!
    private var input: StubInput!
    private var describer: StubDescriber!

    override func setUp() {
        super.setUp()
        bridge = StubBridge()
        input = StubInput()
        describer = StubDescriber()
    }

    /// A read showing `texts`, one row each, in the window's content area.
    private func screen(_ texts: String...) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: texts.enumerated().map { index, text in
                TapPoint(text: text, tapX: 200, tapY: Double(300 + 60 * index), confidence: 0.95)
            },
            screenshotBase64: "")
    }

    private func collect(maxScrolls: Int, anchor: CGPoint? = nil) -> CalibrationScroller.ScrollResult? {
        CalibrationScroller.collectFullPage(describer: describer, input: input, bridge: bridge,
                                            maxScrolls: maxScrolls, anchor: anchor)
    }

    // MARK: - Why the scrolling stopped

    func testAListThatStopsChangingEndsAtTheEndOfContent() {
        describer.describeResults = [screen("Row 1", "Row 2"), screen("Row 3", "Row 4"),
                                     screen("Row 3", "Row 4")]
        let result = collect(maxScrolls: 10)
        XCTAssertEqual(result?.stopReason, .endOfContent)
        XCTAssertEqual(result?.scrollCount, 2)
    }

    func testAListStillChangingWhenTheBudgetRunsOutSaysSo() {
        describer.describeResults = [screen("Row 1"), screen("Row 2"), screen("Row 3"), screen("Row 4")]
        let result = collect(maxScrolls: 2)
        XCTAssertEqual(result?.stopReason, .maxScrolls)
        XCTAssertEqual(result?.scrollCount, 2)
    }

    func testAScrollThatCannotBeSentSaysSo() {
        describer.describeResult = screen("Row 1")
        input.swipeResult = "the gesture was refused"
        let result = collect(maxScrolls: 5)
        XCTAssertEqual(result?.stopReason, .scrollFailed)
        XCTAssertEqual(result?.scrollCount, 0)
    }

    func testAScreenThatCannotBeReadAfterAScrollSaysSo() {
        describer.describeResults = [screen("Row 1"), nil]
        let result = collect(maxScrolls: 5)
        XCTAssertEqual(result?.stopReason, .readFailed)
    }

    func testAnUnknownWindowScrollsNothing() {
        bridge.windowInfo = nil
        describer.describeResult = screen("Row 1")
        let result = collect(maxScrolls: 5)
        XCTAssertEqual(result?.stopReason, .noWindow)
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }

    // MARK: - Scrolling at a point

    func testAnAnchorScrollsAtThatPointLikeScrollTo() {
        describer.describeResults = [screen("Card 1"), screen("Card 1")]
        let anchor = CGPoint(x: 120, y: 500)
        _ = collect(maxScrolls: 1, anchor: anchor)
        guard let swipe = input.swipeCalls.first,
              let size = bridge.windowInfo?.size,
              let expected = ScrollSeeker.endpoints(fingerDirection: "up", window: size, around: anchor) else {
            return XCTFail("expected one swipe at the anchor")
        }
        XCTAssertEqual(swipe.fromX, expected.fromX)
        XCTAssertEqual(swipe.fromY, expected.fromY)
        XCTAssertEqual(swipe.toY, expected.toY)
        XCTAssertGreaterThan(swipe.fromY, swipe.toY, "the finger moves up to reveal what is below")
    }

    // MARK: - describe_screen

    private func describeScreen(_ args: [String: JSONValue]) -> (text: String, isError: Bool) {
        let server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil), transport: .stdio)
        let registry = makeTestRegistry(bridge: bridge, input: input, describer: describer)
        MirroirMCP.registerScreenTools(server: server, registry: registry)
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string("describe_screen"), "arguments": .object(args)]))
        guard let response = server.handleRequest(request),
              case .object(let result) = response.result,
              case .array(let content) = result["content"],
              case .object(let first) = content.first,
              case .string(let text) = first["text"] else { return ("", false) }
        if case .bool(let isError) = result["isError"] { return (text, isError) }
        return (text, false)
    }

    func testTheFullPageReplySaysWhyTheScrollingStopped() {
        describer.describeResults = [screen("Row 1"), screen("Row 1")]
        let reply = describeScreen(["scroll": .bool(true), "omit_screenshot": .bool(true)])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains("stop_reason=end_of_content"), reply.text)
    }

    func testMaxScrollsBoundsTheFullPageRead() {
        describer.describeResults = [screen("Row 1"), screen("Row 2"), screen("Row 3"), screen("Row 4")]
        let reply = describeScreen(["scroll": .bool(true), "max_scrolls": .number(1),
                                    "omit_screenshot": .bool(true)])
        XCTAssertTrue(reply.text.contains("scroll_count=1 stop_reason=max_scrolls"), reply.text)
        XCTAssertEqual(input.swipeCalls.count, 1)
    }

    func testABadScrollBudgetOrPointIsRefusedBeforeAnyScroll() {
        describer.describeResult = screen("Row 1")
        let zero = describeScreen(["scroll": .bool(true), "max_scrolls": .number(0)])
        XCTAssertTrue(zero.isError)
        XCTAssertTrue(zero.text.contains("max_scrolls must be at least 1"), zero.text)
        let outside = describeScreen(["scroll": .bool(true), "at": .array([.number(5000), .number(10)])])
        XCTAssertTrue(outside.isError)
        XCTAssertTrue(outside.text.contains("at must be [x, y] inside the"), outside.text)
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }

    func testScrollArgumentsWithoutScrollAreRefusedNotDropped() {
        describer.describeResult = screen("Row 1")
        let budget = describeScreen(["max_scrolls": .number(2), "omit_screenshot": .bool(true)])
        XCTAssertTrue(budget.isError, budget.text)
        XCTAssertEqual(budget.text, "max_scrolls applies only with scroll: true")
        let both = describeScreen(["scroll": .bool(false), "max_scrolls": .number(2),
                                   "at": .array([.number(10), .number(10)])])
        XCTAssertTrue(both.isError, both.text)
        XCTAssertEqual(both.text, "max_scrolls and at apply only with scroll: true")
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }
}
