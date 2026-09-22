// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the hold_keys MCP tool handler: argument parsing, validation, delegation, output text.
// ABOUTME: Uses StubInput to record the HeldKeysRequest each call produces.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class HoldKeysToolHandlerTests: XCTestCase {

    private var server: MCPServer!
    private var input: StubInput!

    override func setUp() {
        super.setUp()
        server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil))
        input = StubInput()
        MirroirMCP.registerHoldKeysTools(
            server: server, registry: makeTestRegistry(bridge: StubBridge(), input: input))
    }

    private func call(_ args: [String: JSONValue]) -> (text: String?, isError: Bool) {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string("hold_keys"), "arguments": .object(args)]))
        guard let response = server.handleRequest(request),
              case .object(let result) = response.result else { return (nil, false) }
        var text: String?
        if case .array(let content) = result["content"],
           case .object(let first) = content.first,
           case .string(let value) = first["text"] {
            text = value
        }
        if case .bool(let isError) = result["isError"] { return (text, isError) }
        return (text, false)
    }

    func testKeysOnlyUsesDefaultDuration() throws {
        let result = call(["keys": .array([.string("W"), .string("space")])])
        XCTAssertFalse(result.isError, result.text ?? "nil")
        let request = try XCTUnwrap(input.holdKeysCalls.first)
        XCTAssertEqual(request.keys.map(\.name), ["w", "space"])
        XCTAssertEqual(request.durationMs, HeldKeysRequest.defaultDurationMs)
        XCTAssertNil(request.drag)
        XCTAssertEqual(result.text, "Held w, space for 1000ms")
    }

    func testRightButtonDragIsParsed() throws {
        let result = call([
            "keys": .array([.string("w")]),
            "duration_ms": .number(2_000),
            "drag": .object(["from_x": .number(200), "from_y": .number(300),
                             "to_x": .number(260), "to_y": .number(300),
                             "button": .string("right")]),
        ])
        XCTAssertFalse(result.isError, result.text ?? "nil")
        XCTAssertEqual(input.holdKeysCalls.first?.drag,
                       HeldKeysDrag(fromX: 200, fromY: 300, toX: 260, toY: 300, button: .right))
        XCTAssertEqual(result.text,
                       "Held w for 2000ms while right-dragging from (200, 300) to (260, 300)")
    }

    func testDragButtonDefaultsToLeft() {
        _ = call(["keys": .array([.string("w")]),
                  "drag": .object(["from_x": .number(1), "from_y": .number(2),
                                   "to_x": .number(3), "to_y": .number(4)])])
        XCTAssertEqual(input.holdKeysCalls.first?.drag?.button, .left)
    }

    func testInvalidArgumentsNeverReachInput() {
        XCTAssertTrue(call([:]).isError)
        XCTAssertTrue(call(["keys": .array([])]).isError)
        XCTAssertTrue(call(["keys": .array([.number(1)])]).isError)
        XCTAssertTrue(call(["keys": .array([.string("w")]), "duration_ms": .number(50_000)]).isError)
        let button = call(["keys": .array([.string("w")]),
                           "drag": .object(["from_x": .number(1), "from_y": .number(2),
                                            "to_x": .number(3), "to_y": .number(4),
                                            "button": .string("middle")])])
        XCTAssertTrue(button.isError)
        XCTAssertTrue(button.text?.contains("middle") ?? false)
        XCTAssertTrue(call(["keys": .array([.string("w")]),
                            "drag": .object(["from_x": .number(1)])]).isError)
        XCTAssertTrue(input.holdKeysCalls.isEmpty)
    }

    func testUnmappableKeyIsNamed() {
        let result = call(["keys": .array([.string("w"), .string("f13")])])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text?.contains("'f13'") ?? false, result.text ?? "nil")
        XCTAssertTrue(input.holdKeysCalls.isEmpty)
    }

    func testInputErrorIsReturned() {
        input.holdKeysResult = "CGEvent hold_keys failed"
        let result = call(["keys": .array([.string("w")])])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "CGEvent hold_keys failed")
    }
}
