// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for navigation tool MCP handlers: launch_app, open_url, press_home, press_app_switcher, press_back, spotlight.
// ABOUTME: Verifies parameter validation, permission policy enforcement, and success/failure paths.

import CoreGraphics
import XCTest
import HelperLib
@testable import mirroir_mcp

final class NavigationToolHandlerTests: XCTestCase {

    private var server: MCPServer!
    private var bridge: StubBridge!
    private var input: StubInput!
    private var describer: StubDescriber!

    override func setUp() {
        super.setUp()
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        server = MCPServer(policy: policy)
        bridge = StubBridge()
        input = StubInput()
        describer = StubDescriber()
        let registry = makeTestRegistry(
            bridge: bridge, input: input, describer: describer
        )
        MirroirMCP.registerNavigationTools(
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
        MirroirMCP.registerNavigationTools(
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
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Favorites", tapX: 200, tapY: 120, confidence: 0.9)],
            screenshotBase64: "img")
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

    func testOpenURLBlockedForIPhoneMirroring() {
        input.openURLResult = nil
        let response = callTool("open_url", args: ["url": .string("https://example.com")])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("not supported for iPhone Mirroring") ?? false)
    }

    func testOpenURLSuccessForGenericWindow() {
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        let gwServer = MCPServer(policy: policy)
        let gwCtx = TargetContext(
            name: "browser",
            targetType: "generic-window",
            bundleID: nil,
            bridge: bridge,
            input: input,
            capture: StubCapture(),
            describer: StubDescriber(),
            recorder: StubRecorder(),
            capabilities: [.menuActions]
        )
        let gwRegistry = TargetRegistry(targets: ["browser": gwCtx], defaultName: "browser")
        MirroirMCP.registerNavigationTools(
            server: gwServer, registry: gwRegistry, policy: policy
        )

        input.openURLResult = nil
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "tools/call",
            params: .object([
                "name": .string("open_url"),
                "arguments": .object(["url": .string("https://example.com")]),
            ])
        )
        let response = gwServer.handleRequest(request)!
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

    // MARK: - press_back

    private func describeResult(with elements: [TapPoint]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: elements, screenshotBase64: "base64data"
        )
    }

    func testPressBackTapsOCRChevron() {
        // Chevron at the top of a 410x898 window — must fall inside top 15% zone (y <= 134).
        let chevron = TapPoint(text: "<", tapX: 24, tapY: 60, confidence: 0.95)
        describer.describeResult = describeResult(with: [chevron])

        let response = callTool("press_back")
        XCTAssertFalse(isError(response))
        XCTAssertEqual(input.tapCalls.count, 1)
        XCTAssertEqual(input.tapCalls.first?.x, 24)
        XCTAssertEqual(input.tapCalls.first?.y, 60)
    }

    func testPressBackFallsBackToCanonicalPosition() {
        // No chevron in OCR — handler should tap the iPhone Mirroring portrait
        // fallback (xFraction=0.112, yFraction=0.135 for 410x898).
        describer.describeResult = describeResult(with: [])

        let response = callTool("press_back")
        XCTAssertFalse(isError(response))
        XCTAssertEqual(input.tapCalls.count, 1)
        let call = input.tapCalls.first!
        XCTAssertEqual(call.x, 410.0 * 0.112, accuracy: 0.001)
        XCTAssertEqual(call.y, 898.0 * 0.135, accuracy: 0.001)
    }

    func testPressBackProcessNotRunning() {
        bridge.processRunning = false
        let response = callTool("press_back")
        XCTAssertTrue(isError(response))
        XCTAssertEqual(input.tapCalls.count, 0)
    }

    func testPressBackOCRFailure() {
        describer.describeResult = nil
        let response = callTool("press_back")
        XCTAssertTrue(isError(response))
        XCTAssertEqual(input.tapCalls.count, 0)
        XCTAssertTrue(extractText(response)?.contains("Failed to capture") ?? false)
    }
}
