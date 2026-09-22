// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the pinch and rotate MCP tool handlers: argument parsing, validation, delegation.
// ABOUTME: Uses StubInput to record the GestureRequest each call produces.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class GestureToolHandlerTests: XCTestCase {

    private var server: MCPServer!
    private var input: StubInput!

    override func setUp() {
        super.setUp()
        server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil))
        input = StubInput()
        MirroirMCP.registerGestureTools(
            server: server, registry: makeTestRegistry(bridge: StubBridge(), input: input))
    }

    private func call(_ tool: String, _ args: [String: JSONValue]) -> (text: String?, isError: Bool) {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string(tool), "arguments": .object(args)]))
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

    func testPinchDelegatesWithDefaultDuration() {
        let result = call("pinch", ["x": .number(100), "y": .number(200), "scale": .number(2)])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(input.gestureCalls, [GestureRequest(
            x: 100, y: 200, gesture: .pinch(scale: 2), durationMs: GestureRequest.defaultDurationMs)])
        XCTAssertTrue(result.text?.contains("Pinched at (100, 200)") ?? false, result.text ?? "nil")
    }

    func testRotatePassesDegreesAndDuration() {
        let result = call("rotate", ["x": .number(10), "y": .number(20), "degrees": .number(-45),
                                     "duration_ms": .number(800)])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(input.gestureCalls, [GestureRequest(
            x: 10, y: 20, gesture: .rotate(degrees: -45), durationMs: 800)])
        XCTAssertTrue(result.text?.contains("by -45.0 degrees") ?? false, result.text ?? "nil")
    }

    func testInvalidArgumentsNeverReachInput() {
        XCTAssertTrue(call("pinch", ["x": .number(1), "y": .number(1), "scale": .number(1)]).isError)
        XCTAssertTrue(call("pinch", ["x": .number(1), "y": .number(1), "scale": .number(50)]).isError)
        XCTAssertTrue(call("rotate", ["x": .number(1), "y": .number(1), "degrees": .number(0)]).isError)
        XCTAssertTrue(call("rotate", ["x": .number(1), "y": .number(1), "degrees": .number(30),
                                      "duration_ms": .number(10)]).isError)
        XCTAssertTrue(input.gestureCalls.isEmpty)
    }

    func testMissingArgumentsNameTheAmount() {
        let pinch = call("pinch", ["x": .number(1), "y": .number(1)])
        XCTAssertTrue(pinch.isError)
        XCTAssertTrue(pinch.text?.contains("scale") ?? false)
        let rotate = call("rotate", ["x": .number(1), "degrees": .number(30)])
        XCTAssertTrue(rotate.isError)
        XCTAssertTrue(rotate.text?.contains("degrees") ?? false)
        XCTAssertTrue(input.gestureCalls.isEmpty)
    }

    func testInputErrorIsReturned() {
        input.gestureResult = InputSimulation.noTrackpadMessage(tool: "pinch")
        let result = call("pinch", ["x": .number(1), "y": .number(1), "scale": .number(0.5)])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, InputSimulation.noTrackpadMessage(tool: "pinch"))
    }

    func testDescriptionsExplainDeliveryAndGames() {
        let request = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "tools/list", params: nil)
        guard let response = server.handleRequest(request),
              case .object(let result) = response.result,
              case .array(let tools) = result["tools"] else { return XCTFail("no tools/list result") }
        var descriptions: [String: String] = [:]
        for case .object(let tool) in tools {
            if case .string(let name) = tool["name"], case .string(let text) = tool["description"] {
                descriptions[name] = text
            }
        }
        for name in ["pinch", "rotate"] {
            let text = descriptions[name] ?? ""
            XCTAssertTrue(text.contains("UIKit two-finger gesture"), "\(name): \(text)")
            XCTAssertTrue(text.contains("games"), "\(name): \(text)")
        }
    }
}
