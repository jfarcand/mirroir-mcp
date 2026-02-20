// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for input tool MCP handlers: tap, swipe, drag, type_text, press_key, long_press, double_tap, shake.
// ABOUTME: Verifies parameter validation, error propagation, and success message formatting.

import XCTest
import HelperLib
@testable import iphone_mirroir_mcp

final class InputToolHandlerTests: XCTestCase {

    private var server: MCPServer!
    private var bridge: StubBridge!
    private var input: StubInput!

    override func setUp() {
        super.setUp()
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        server = MCPServer(policy: policy)
        bridge = StubBridge()
        input = StubInput()
        let registry = makeTestRegistry(bridge: bridge, input: input)
        IPhoneMirroirMCP.registerInputTools(server: server, registry: registry)
    }

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

    // MARK: - tap

    func testTapMissingParams() {
        let response = callTool("tap", args: [:])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Missing required parameters") ?? false)
    }

    func testTapSuccess() {
        input.tapResult = nil // nil = success
        let response = callTool("tap", args: ["x": .number(100), "y": .number(200)])
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertEqual(text, "Tapped at (100, 200)")
    }

    func testTapSubsystemError() {
        input.tapResult = "Helper click failed"
        let response = callTool("tap", args: ["x": .number(100), "y": .number(200)])
        XCTAssertTrue(isError(response))
        XCTAssertEqual(extractText(response), "Helper click failed")
    }

    // MARK: - swipe

    func testSwipeMissingParams() {
        let response = callTool("swipe", args: ["from_x": .number(0)])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Missing required parameters") ?? false)
    }

    func testSwipeSuccessWithDefaultDuration() {
        input.swipeResult = nil
        let response = callTool("swipe", args: [
            "from_x": .number(100), "from_y": .number(200),
            "to_x": .number(100), "to_y": .number(400),
        ])
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Swiped from") ?? false)
    }

    // MARK: - drag

    func testDragMissingParams() {
        let response = callTool("drag", args: ["from_x": .number(0)])
        XCTAssertTrue(isError(response))
    }

    func testDragSuccess() {
        input.dragResult = nil
        let response = callTool("drag", args: [
            "from_x": .number(100), "from_y": .number(200),
            "to_x": .number(150), "to_y": .number(250),
        ])
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Dragged from") ?? false)
        XCTAssertTrue(text?.contains("1000ms") ?? false) // default duration
    }

    // MARK: - type_text

    func testTypeTextMissingText() {
        let response = callTool("type_text", args: [:])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Missing required parameter") ?? false)
    }

    func testTypeTextHelperFailure() {
        input.typeTextResult = TypeResult(success: false, warning: nil, error: "Helper unavailable")
        let response = callTool("type_text", args: ["text": .string("hello")])
        XCTAssertTrue(isError(response))
        XCTAssertEqual(extractText(response), "Helper unavailable")
    }

    func testTypeTextSuccess() {
        input.typeTextResult = TypeResult(success: true, warning: nil, error: nil)
        let response = callTool("type_text", args: ["text": .string("hello")])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(extractText(response), "Typed 5 characters")
    }

    // MARK: - press_key

    func testPressKeyMissingKey() {
        let response = callTool("press_key", args: [:])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Missing required parameter") ?? false)
    }

    func testPressKeyWithModifiers() {
        input.pressKeyResult = TypeResult(success: true, warning: nil, error: nil)
        let response = callTool("press_key", args: [
            "key": .string("l"),
            "modifiers": .array([.string("command")]),
        ])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(extractText(response), "Pressed command+l")
    }

    func testPressKeyWithoutModifiers() {
        input.pressKeyResult = TypeResult(success: true, warning: nil, error: nil)
        let response = callTool("press_key", args: ["key": .string("return")])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(extractText(response), "Pressed return")
    }

    // MARK: - long_press

    func testLongPressMissingParams() {
        let response = callTool("long_press", args: [:])
        XCTAssertTrue(isError(response))
    }

    func testLongPressDefaultDuration() {
        input.longPressResult = nil
        let response = callTool("long_press", args: ["x": .number(50), "y": .number(100)])
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("500ms") ?? false)
    }

    // MARK: - double_tap

    func testDoubleTapSuccess() {
        input.doubleTapResult = nil
        let response = callTool("double_tap", args: ["x": .number(50), "y": .number(100)])
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertEqual(text, "Double-tapped at (50, 100)")
    }

    // MARK: - shake

    func testShakeHelperUnavailable() {
        input.shakeResult = TypeResult(success: false, warning: nil, error: "Helper unavailable")
        let response = callTool("shake")
        XCTAssertTrue(isError(response))
    }

    func testShakeSuccess() {
        input.shakeResult = TypeResult(success: true, warning: nil, error: nil)
        let response = callTool("shake")
        XCTAssertFalse(isError(response))
        XCTAssertEqual(extractText(response), "Triggered shake gesture (Ctrl+Cmd+Z)")
    }
}
