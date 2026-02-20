// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for target management MCP tools: list_targets, switch_target.
// ABOUTME: Verifies target listing, switching, and error handling.

import XCTest
import HelperLib
@testable import iphone_mirroir_mcp

final class TargetToolHandlerTests: XCTestCase {

    private var server: MCPServer!
    private var registry: TargetRegistry!

    override func setUp() {
        super.setUp()
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        server = MCPServer(policy: policy)

        let iphoneBridge = StubBridge()
        iphoneBridge.targetName = "iphone"
        let androidBridge = StubBridge()
        androidBridge.targetName = "android"

        let iphoneCtx = TargetContext(
            name: "iphone", bridge: iphoneBridge, input: StubInput(),
            capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder(),
            capabilities: [.menuActions, .spotlight, .home, .appSwitcher])
        let androidCtx = TargetContext(
            name: "android", bridge: androidBridge, input: StubInput(),
            capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder(),
            capabilities: [])

        registry = TargetRegistry(
            targets: ["iphone": iphoneCtx, "android": androidCtx],
            defaultName: "iphone")
        IPhoneMirroirMCP.registerTargetTools(server: server, registry: registry)
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

    // MARK: - list_targets

    func testListTargetsShowsAll() {
        let response = callTool("list_targets")
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("iphone") ?? false)
        XCTAssertTrue(text?.contains("android") ?? false)
    }

    func testListTargetsShowsActiveMarker() {
        let response = callTool("list_targets")
        let text = extractText(response)
        XCTAssertNotNil(text)
        // "iphone" is the default active target
        XCTAssertTrue(text?.contains("iphone (active)") ?? false)
        // "android" should NOT have the active marker
        XCTAssertFalse(text?.contains("android (active)") ?? true)
    }

    // MARK: - switch_target

    func testSwitchTargetSuccess() {
        let response = callTool("switch_target", args: ["target": .string("android")])
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("android") ?? false)
        XCTAssertEqual(registry.activeTargetName, "android")
    }

    func testSwitchTargetUnknownFails() {
        let response = callTool("switch_target", args: ["target": .string("nonexistent")])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Unknown target") ?? false)
        // Active target should remain unchanged
        XCTAssertEqual(registry.activeTargetName, "iphone")
    }

    func testSwitchTargetMissingParam() {
        let response = callTool("switch_target", args: [:])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Missing required parameter") ?? false)
    }
}
