// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for navigation tool MCP handlers: launch_app, open_url, press_home, press_app_switcher, spotlight.
// ABOUTME: Verifies parameter validation, permission policy enforcement, and success/failure paths.

import XCTest
import HelperLib
@testable import iphone_mirroir_mcp

final class NavigationToolHandlerTests: XCTestCase {

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
        IPhoneMirroirMCP.registerNavigationTools(
            server: server, registry: registry, policy: policy
        )
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

    // MARK: - launch_app

    func testLaunchAppMissingName() {
        let response = callTool("launch_app")
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Missing required parameter") ?? false)
    }

    func testLaunchAppBlockedByPolicy() {
        let config = PermissionConfig(allow: ["*"], blockedApps: ["Settings"])
        let policy = PermissionPolicy(skipPermissions: true, config: config)
        let policyServer = MCPServer(policy: policy)
        let policyRegistry = makeTestRegistry(bridge: bridge, input: input)
        IPhoneMirroirMCP.registerNavigationTools(
            server: policyServer, registry: policyRegistry, policy: policy
        )

        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "tools/call",
            params: .object([
                "name": .string("launch_app"),
                "arguments": .object(["name": .string("Settings")]),
            ])
        )
        let response = policyServer.handleRequest(request)!
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("blocked") ?? false)
    }

    func testLaunchAppSuccess() {
        input.launchAppResult = nil
        let response = callTool("launch_app", args: ["name": .string("Safari")])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(extractText(response), "Launched 'Safari' via Spotlight")
    }

    // MARK: - open_url

    func testOpenURLMissingURL() {
        let response = callTool("open_url")
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Missing required parameter") ?? false)
    }

    func testOpenURLSuccess() {
        input.openURLResult = nil
        let response = callTool("open_url", args: ["url": .string("https://example.com")])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(extractText(response), "Opened URL: https://example.com")
    }

    // MARK: - press_home

    func testPressHomeSuccess() {
        bridge.menuActionResult = true
        let response = callTool("press_home")
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Home") ?? false)
    }

    func testPressHomeFailure() {
        bridge.menuActionResult = false
        let response = callTool("press_home")
        XCTAssertTrue(isError(response))
    }

    // MARK: - press_app_switcher

    func testPressAppSwitcherSuccess() {
        bridge.menuActionResult = true
        let response = callTool("press_app_switcher")
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("App Switcher") ?? false)
    }

    func testPressAppSwitcherFailure() {
        bridge.menuActionResult = false
        let response = callTool("press_app_switcher")
        XCTAssertTrue(isError(response))
    }

    // MARK: - spotlight

    func testSpotlightSuccess() {
        bridge.menuActionResult = true
        let response = callTool("spotlight")
        XCTAssertFalse(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Spotlight") ?? false)
    }

    func testSpotlightFailure() {
        bridge.menuActionResult = false
        let response = callTool("spotlight")
        XCTAssertTrue(isError(response))
    }
}
