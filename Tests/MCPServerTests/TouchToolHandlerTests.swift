// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the touch MCP tool handler: argument parsing, delegation, and result text.
// ABOUTME: Uses StubInput to record the TouchCommand each call produces.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

final class TouchToolHandlerTests: XCTestCase {

    private var server: MCPServer!
    private var input: StubInput!

    override func setUp() {
        super.setUp()
        server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil))
        input = StubInput()
        MirroirMCP.registerTouchTools(
            server: server, registry: makeTestRegistry(bridge: StubBridge(), input: input))
    }

    private func call(_ args: [String: JSONValue]) -> (text: String?, isError: Bool) {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string("touch"), "arguments": .object(args)]))
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

    func testBeginPassesCoordinates() {
        let result = call(["action": .string("begin"), "x": .number(12), "y": .number(34)])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(input.touchCalls, [.begin(x: 12, y: 34)])
        XCTAssertTrue(result.text?.contains("Touch began at (12, 34)") ?? false)
    }

    func testMoveDefaultsDuration() {
        _ = call(["action": .string("move"), "x": .number(1), "y": .number(2)])
        XCTAssertEqual(input.touchCalls,
                       [.move(x: 1, y: 2, durationMs: TouchSession.defaultMoveDurationMs)])
    }

    func testMovePassesDuration() {
        _ = call(["action": .string("move"), "x": .number(1), "y": .number(2),
                  "duration_ms": .number(250)])
        XCTAssertEqual(input.touchCalls, [.move(x: 1, y: 2, durationMs: 250)])
    }

    func testMoveRefusesDurationOutsideBounds() {
        for duration in [0.0, Double(TouchSession.maxMoveDurationMs + 1), 60_000, -5] {
            let result = call(["action": .string("move"), "x": .number(1), "y": .number(2),
                               "duration_ms": .number(duration)])
            XCTAssertTrue(result.isError, "duration \(duration) must be refused")
            XCTAssertTrue(result.text?.contains("duration_ms must be between") ?? false,
                          result.text ?? "nil")
        }
        XCTAssertTrue(input.touchCalls.isEmpty)
    }

    func testMoveRefusesUnrepresentableDurationWithoutTrapping() {
        for duration in [1e20, -1e20, Double.infinity, Double.nan] {
            let result = call(["action": .string("move"), "x": .number(1), "y": .number(2),
                               "duration_ms": .number(duration)])
            XCTAssertTrue(result.isError, "duration \(duration) must be refused")
            XCTAssertTrue(result.text?.contains("not an integer") ?? false, result.text ?? "nil")
        }
        XCTAssertTrue(input.touchCalls.isEmpty)
    }

    func testBeginRefusesNonFiniteCoordinates() {
        let result = call(["action": .string("begin"), "x": .number(.infinity), "y": .number(1)])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text?.contains("finite") ?? false)
        XCTAssertTrue(input.touchCalls.isEmpty)
    }

    func testEndAndCancel() {
        XCTAssertFalse(call(["action": .string("end")]).isError)
        let cancelled = call(["action": .string("cancel")])
        XCTAssertFalse(cancelled.isError)
        XCTAssertEqual(input.touchCalls, [.end, .cancel])
        XCTAssertTrue(cancelled.text?.contains("released anyway") ?? false)
    }

    func testMissingAction() {
        let result = call([:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text?.contains("Missing required parameter: action") ?? false)
        XCTAssertTrue(input.touchCalls.isEmpty)
    }

    func testInvalidAction() {
        let result = call(["action": .string("hold")])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text?.contains("Invalid action 'hold'") ?? false)
    }

    func testBeginWithoutCoordinates() {
        let result = call(["action": .string("begin"), "x": .number(1)])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text?.contains("requires x, y") ?? false)
        XCTAssertTrue(input.touchCalls.isEmpty)
    }

    func testSessionErrorIsReported() {
        input.touchResult = .failure(.alreadyHeld(at: CGPoint(x: 5, y: 6)))
        let result = call(["action": .string("begin"), "x": .number(1), "y": .number(1)])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text?.contains("already held at (5, 6)") ?? false)
        XCTAssertTrue(result.text?.contains("touch(action:\"cancel\")") ?? false)
    }
}
