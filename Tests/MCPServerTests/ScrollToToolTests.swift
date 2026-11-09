// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the scroll_to MCP tool handler: scrolling until an element becomes visible via OCR.
// ABOUTME: Verifies parameter validation, scroll direction coordinates, exhaustion detection, and error propagation.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class ScrollToToolTests: XCTestCase {

    private var server: MCPServer!
    private var bridge: StubBridge!
    private var input: StubInput!
    private var describer: StubDescriber!

    override func setUp() {
        super.setUp()
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        server = MCPServer(policy: policy, transport: .stdio)
        bridge = StubBridge()
        input = StubInput()
        describer = StubDescriber()
        let registry = makeTestRegistry(bridge: bridge, input: input, describer: describer)
        MirroirMCP.registerScrollToTools(server: server, registry: registry)
    }

    // MARK: - Helpers

    private func callTool(_ name: String, args: [String: JSONValue] = [:]) -> JSONRPCResponse {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": .object(args),
            ])
        )
        return server.handleRequest(request)!
    }

    private func extractText(_ response: JSONRPCResponse) -> String? {
        guard case .object(let result) = response.result,
              case .array(let content) = result["content"],
              case .object(let textObj) = content.first,
              case .string(let text) = textObj["text"] else { return nil }
        return text
    }

    private func isError(_ response: JSONRPCResponse) -> Bool {
        guard case .object(let result) = response.result,
              case .bool(let isErr) = result["isError"] else { return false }
        return isErr
    }

    private func makeDescribeResult(texts: [String]) -> ScreenDescriber.DescribeResult {
        let elements = texts.map { TapPoint(text: $0, tapX: 100, tapY: 200, confidence: 0.95) }
        return ScreenDescriber.DescribeResult(
            elements: elements, screenshotBase64: "dGVzdA=="
        )
    }

    // MARK: - Already Visible

    func testScrollToAlreadyVisible() {
        describer.describeResults = [
            makeDescribeResult(texts: ["Settings", "General", "About"])
        ]
        let response = callTool("scroll_to", args: ["label": .string("General")])
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertEqual(text, "'General' is already visible on screen")
        XCTAssertTrue(input.swipeCalls.isEmpty, "Should not swipe when already visible")
    }

    // MARK: - Found After Scrolling

    func testScrollToFoundAfterOneScroll() {
        describer.describeResults = [
            makeDescribeResult(texts: ["Settings", "General"]),
            makeDescribeResult(texts: ["General", "About", "Privacy"]),
        ]
        let response = callTool("scroll_to", args: ["label": .string("Privacy")])
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertEqual(text, "Found 'Privacy' after 1 scroll(s)")
        XCTAssertEqual(input.swipeCalls.count, 1)
    }

    // MARK: - Scroll Exhaustion

    /// One read that looks like the last is not the end: the content has ended
    /// once it reads the same two scrolls in a row.
    func testScrollToTheEndOfTheContent() {
        let sameResult = makeDescribeResult(texts: ["Settings", "General"])
        // The read before any scroll, then a scroll that moved, then two that did not.
        describer.describeResults = [
            makeDescribeResult(texts: ["Settings"]),
            sameResult,
            sameResult,
            sameResult,
        ]
        let response = callTool("scroll_to", args: ["label": .string("Privacy")])
        XCTAssertTrue(isError(response))
        XCTAssertEqual(
            extractText(response),
            "'Privacy' not found: the content stopped moving after 3 scroll(s) (stop_reason=end_of_content)")
        XCTAssertEqual(input.swipeCalls.count, 3)
    }

    func testAtScrollsAroundThatPoint() {
        describer.describeResults = [
            makeDescribeResult(texts: ["A"]), makeDescribeResult(texts: ["A", "Privacy"]),
        ]
        let response = callTool("scroll_to", args: [
            "label": .string("Privacy"), "at": .array([.number(100), .number(600)]),
        ])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(input.swipeCalls.first?.fromX, 100)
        let call = input.swipeCalls.first
        XCTAssertEqual(((call?.fromY ?? 0) + (call?.toY ?? 0)) / 2, 600, accuracy: 0.001)
    }

    func testAtOutsideTheWindowIsRefused() {
        describer.describeResults = [makeDescribeResult(texts: ["A"])]
        for at: JSONValue in [.array([.number(900), .number(100)]), .array([.number(10)]), .string("centre")] {
            let response = callTool("scroll_to", args: ["label": .string("Privacy"), "at": at])
            XCTAssertTrue(isError(response))
            XCTAssertEqual(extractText(response), "at must be [x, y] inside the 410x898 window")
        }
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }

    // MARK: - Max Scrolls Reached

    func testScrollToMaxReached() {
        // Each describe returns different content so exhaustion doesn't trigger,
        // but label is never found.
        var results: [ScreenDescriber.DescribeResult?] = [
            makeDescribeResult(texts: ["Screen0"])  // initial check
        ]
        for i in 1...3 {
            results.append(makeDescribeResult(texts: ["Screen\(i)"]))
        }
        describer.describeResults = results
        let response = callTool("scroll_to", args: [
            "label": .string("NotHere"),
            "max_scrolls": .number(3),
        ])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertEqual(text, "'NotHere' not found after 3 scroll(s) (stop_reason=max_scrolls)")
    }

    // MARK: - Swipe Failure

    func testScrollToSwipeFailure() {
        describer.describeResults = [
            makeDescribeResult(texts: ["Settings"])
        ]
        input.swipeResult = "CGEvent post failed"
        let response = callTool("scroll_to", args: ["label": .string("About")])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertEqual(text, "Swipe failed: CGEvent post failed")
    }

    // MARK: - Missing Label

    func testScrollToMissingLabel() {
        let response = callTool("scroll_to", args: [:])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertEqual(text, "Missing required parameter: label (string)")
    }

    // MARK: - Unknown Direction

    func testScrollToUnknownDirection() {
        describer.describeResults = [
            makeDescribeResult(texts: ["Settings"])
        ]
        let response = callTool("scroll_to", args: [
            "label": .string("About"),
            "direction": .string("diagonal"),
        ])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertEqual(text, "Unknown direction: diagonal. Use down/up/left/right.")
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }

    // MARK: - Scroll Direction Coordinates

    /// With no direction, scroll_to looks further down the page: the finger moves up.
    func testDefaultDirectionRevealsContentBelow() {
        describer.describeResults = [
            makeDescribeResult(texts: ["Settings"]),
            makeDescribeResult(texts: ["Settings", "Target"]),
        ]
        XCTAssertFalse(isError(callTool("scroll_to", args: ["label": .string("Target")])))
        let call = input.swipeCalls[0]
        XCTAssertGreaterThan(call.fromY, call.toY)
    }

    func testScrollUpCoordinates() {
        describer.describeResults = [
            makeDescribeResult(texts: ["Settings"]),
            makeDescribeResult(texts: ["Settings", "Target"]),
        ]
        let response = callTool("scroll_to", args: [
            "label": .string("Target"),
            "direction": .string("up"),
        ])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(input.swipeCalls.count, 1)
        let call = input.swipeCalls[0]
        XCTAssertLessThan(call.fromY, call.toY, "content above: the finger moves down")
        XCTAssertEqual(call.fromX, call.toX, "a vertical scroll keeps X")
    }

    func testScrollDownCoordinates() {
        describer.describeResults = [
            makeDescribeResult(texts: ["Settings"]),
            makeDescribeResult(texts: ["Settings", "Target"]),
        ]
        let response = callTool("scroll_to", args: [
            "label": .string("Target"),
            "direction": .string("down"),
        ])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(input.swipeCalls.count, 1)
        let call = input.swipeCalls[0]
        XCTAssertGreaterThan(call.fromY, call.toY, "content below: the finger moves up")
        XCTAssertEqual(call.fromX, call.toX, "a vertical scroll keeps X")
    }

    func testScrollLeftCoordinates() {
        describer.describeResults = [
            makeDescribeResult(texts: ["Settings"]),
            makeDescribeResult(texts: ["Settings", "Target"]),
        ]
        let response = callTool("scroll_to", args: [
            "label": .string("Target"),
            "direction": .string("left"),
        ])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(input.swipeCalls.count, 1)
        let call = input.swipeCalls[0]
        XCTAssertLessThan(call.fromX, call.toX, "content to the left: the finger moves right")
        XCTAssertEqual(call.fromY, call.toY, "a sideways scroll keeps Y")
    }

    func testScrollRightCoordinates() {
        describer.describeResults = [
            makeDescribeResult(texts: ["Settings"]),
            makeDescribeResult(texts: ["Settings", "Target"]),
        ]
        let response = callTool("scroll_to", args: [
            "label": .string("Target"),
            "direction": .string("right"),
        ])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(input.swipeCalls.count, 1)
        let call = input.swipeCalls[0]
        XCTAssertGreaterThan(call.fromX, call.toX, "content to the right: the finger moves left")
        XCTAssertEqual(call.fromY, call.toY, "a sideways scroll keeps Y")
    }
}
