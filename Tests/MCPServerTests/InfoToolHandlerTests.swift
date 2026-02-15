// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for info tool MCP handlers: get_orientation, status, check_health.
// ABOUTME: Verifies orientation reporting, status formatting, and health check diagnostics.

import XCTest
import HelperLib
@testable import iphone_mirroir_mcp

final class InfoToolHandlerTests: XCTestCase {

    private var server: MCPServer!
    private var bridge: StubBridge!
    private var input: StubInput!
    private var capture: StubCapture!

    override func setUp() {
        super.setUp()
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        server = MCPServer(policy: policy)
        bridge = StubBridge()
        input = StubInput()
        capture = StubCapture()
        capture.captureResult = "base64data"
        IPhoneMirroirMCP.registerInfoTools(server: server, bridge: bridge, input: input,
                                            capture: capture)
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

    // MARK: - get_orientation

    func testGetOrientationPortrait() {
        bridge.orientation = .portrait
        let response = callTool("get_orientation")
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("portrait") ?? false)
    }

    func testGetOrientationLandscape() {
        bridge.orientation = .landscape
        bridge.windowInfo = WindowInfo(
            windowID: 1, position: .zero,
            size: CGSize(width: 898, height: 410), pid: 1
        )
        let response = callTool("get_orientation")
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("landscape") ?? false)
    }

    func testGetOrientationUnavailable() {
        bridge.orientation = nil
        let response = callTool("get_orientation")
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Cannot determine") ?? false)
    }

    // MARK: - status

    func testStatusConnected() {
        bridge.state = .connected
        input.statusDict = ["ok": true, "keyboard_ready": true, "pointing_ready": true]
        let response = callTool("status")
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Connected") ?? false)
        XCTAssertTrue(text?.contains("410x898") ?? false) // window size
        XCTAssertTrue(text?.contains("Helper: connected") ?? false)
    }

    func testStatusNotRunning() {
        bridge.state = .notRunning
        input.statusDict = nil
        let response = callTool("status")
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Not running") ?? false)
        XCTAssertTrue(text?.contains("Helper: not running") ?? false)
    }

    func testStatusPaused() {
        bridge.state = .paused
        let response = callTool("status")
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Paused") ?? false)
    }

    func testStatusHelperNotRunning() {
        bridge.state = .connected
        input.statusDict = nil
        let response = callTool("status")
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Helper: not running") ?? false)
    }

    // MARK: - check_health

    func testCheckHealthAllOk() {
        bridge.state = .connected
        input.statusDict = ["ok": true, "keyboard_ready": true, "pointing_ready": true]
        capture.captureResult = "base64data"
        let response = callTool("check_health")
        XCTAssertFalse(isError(response))
        let text = extractText(response)!
        XCTAssertTrue(text.contains("All checks passed"))
        XCTAssertTrue(text.contains("[ok] iPhone Mirroring app is running"))
        XCTAssertTrue(text.contains("[ok] Mirroring connected"))
        XCTAssertTrue(text.contains("[ok] Helper daemon connected"))
        XCTAssertTrue(text.contains("[ok] Screen capture working"))
    }

    func testCheckHealthNotRunning() {
        bridge.processRunning = false
        bridge.state = .notRunning
        input.statusDict = nil
        capture.captureResult = nil
        let response = callTool("check_health")
        let text = extractText(response)!
        XCTAssertTrue(text.contains("Issues detected"))
        XCTAssertTrue(text.contains("[FAIL] iPhone Mirroring app is not running"))
    }

    func testCheckHealthPaused() {
        bridge.state = .paused
        let response = callTool("check_health")
        let text = extractText(response)!
        XCTAssertTrue(text.contains("[WARN] Mirroring is paused"))
    }

    func testCheckHealthHelperDown() {
        bridge.state = .connected
        input.statusDict = nil
        let response = callTool("check_health")
        let text = extractText(response)!
        XCTAssertTrue(text.contains("[FAIL] Helper daemon not reachable"))
    }

    func testCheckHealthCaptureFailed() {
        bridge.state = .connected
        capture.captureResult = nil
        let response = callTool("check_health")
        let text = extractText(response)!
        XCTAssertTrue(text.contains("[FAIL] Screen capture failed"))
    }
}
