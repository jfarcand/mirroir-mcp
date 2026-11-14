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
        server = MCPServer(policy: policy, transport: .stdio)
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
        let policyServer = MCPServer(policy: policy, transport: .stdio)
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
        XCTAssertEqual(extractText(response), "Launched 'Safari'")
    }

    // MARK: - open_url

    func testOpenURLMissingURL() {
        let response = callTool("open_url")
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Missing required parameter") ?? false)
    }

    func testOpenURLDrivesSafariOnIPhoneMirroring() {
        // The tool and a scenario's `open_url:` step take the same path
        // (InputSimulation.openURL), so they give the same answer.
        input.openURLResult = nil
        let response = callTool("open_url", args: ["url": .string("https://example.com/a/b")])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(extractText(response), "Opened URL: https://example.com/a/b")
    }

    func testOpenURLReportsInputFailureOnIPhoneMirroring() {
        input.openURLResult = "Failed to select address bar"
        let response = callTool("open_url", args: ["url": .string("https://example.com")])
        XCTAssertTrue(isError(response))
        XCTAssertEqual(extractText(response), "Failed to select address bar")
    }

    /// open_url opens Safari through iPhone Spotlight, which a Mac window does
    /// not have: it is refused there, and nothing is sent.
    func testOpenURLIsUnsupportedOnAGenericWindow() {
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        let gwServer = MCPServer(policy: policy, transport: .stdio)
        let gwCtx = TargetContext(
            name: "browser",
            targetType: "macos-app",
            bundleID: nil,
            bridge: bridge,
            input: input,
            capture: StubCapture(),
            describer: StubDescriber(),
            recorder: StubRecorder()
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
        XCTAssertTrue(isError(response))
        XCTAssertEqual(extractText(response), MacOSAppTarget.profile.refusal(
            of: .openURL, targetName: "browser", supportedOn: []))
        XCTAssertEqual(input.openURLCalls, [])
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

    /// carnet#45: the menu item answers while the session is paused, but the
    /// iPhone receives nothing. The refusal is returned and nothing is pressed.
    func testPressHomeOnAPausedSessionThatCannotBeFreedFailsWithoutPressing() {
        input.ensureConnectedResult = "Target 'iphone' is paused: Connection Paused."
        let response = callTool("press_home")
        XCTAssertTrue(isError(response))
        XCTAssertEqual(extractText(response), "Target 'iphone' is paused: Connection Paused.")
        XCTAssertTrue(bridge.menuActionCalls.isEmpty)
    }

    func testPressHomeThatLeavesTheSessionPausedIsNotASuccess() {
        bridge.state = .paused
        let response = callTool("press_home")
        XCTAssertTrue(isError(response))
        XCTAssertTrue(extractText(response)?.contains("the iPhone did not receive it") ?? false,
                      extractText(response) ?? "")
    }

    /// After an app opened from Spotlight, iOS answers Home with Spotlight
    /// again (XR, 2026-11-13); a second press reaches the Home Screen.
    private var spotlightHoldingAQuery: ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(elements: [
            TapPoint(text: "Meilleur résultat", tapX: 85, tapY: 107, confidence: 0.9),
            TapPoint(text: "Q Notes — Ouvrir", tapX: 140, tapY: 873, confidence: 0.9),
        ], screenshotBase64: "img")
    }

    private var homeScreen: ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(elements: [
            TapPoint(text: "Notes", tapX: 166, tapY: 499, confidence: 0.9),
            TapPoint(text: "Q Rechercher", tapX: 215, tapY: 783, confidence: 0.9),
        ], screenshotBase64: "img")
    }

    /// An app in front, read before the press.
    private var notesApp: ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(elements: [
            TapPoint(text: "< Dossiers", tapX: 50, tapY: 108, confidence: 0.9),
            TapPoint(text: "93 notes", tapX: 215, tapY: 880, confidence: 0.9),
        ], screenshotBase64: "img")
    }

    private func useWindow() {
        bridge.windowInfo = WindowInfo(windowID: 1, position: .zero,
                                       size: CGSize(width: 430, height: 942), pid: 1)
    }

    func testPressHomeThatBringsBackSpotlightPressesHomeAgain() {
        useWindow()
        describer.describeResults = [notesApp, spotlightHoldingAQuery, homeScreen]
        let response = callTool("press_home")
        XCTAssertFalse(isError(response), extractText(response) ?? "")
        XCTAssertEqual(bridge.menuActionCalls.map(\.item), ["Home Screen", "Home Screen"])
    }

    /// A dropped press leaves the app in front: Home is pressed again.
    func testPressHomeThatLeavesTheScreenUnchangedPressesHomeAgain() {
        useWindow()
        describer.describeResults = [notesApp, notesApp, homeScreen]
        XCTAssertFalse(isError(callTool("press_home")))
        XCTAssertEqual(bridge.menuActionCalls.count, 2)
    }

    func testPressHomeLeavingTheHomeScreenPressesOnce() {
        useWindow()
        describer.describeResults = [notesApp, homeScreen]
        XCTAssertFalse(isError(callTool("press_home")))
        XCTAssertEqual(bridge.menuActionCalls.map(\.item), ["Home Screen"])
    }

    func testPressHomeOnTheHomeScreenIsOnePress() {
        useWindow()
        describer.describeResults = [homeScreen, homeScreen]
        XCTAssertFalse(isError(callTool("press_home")))
        XCTAssertEqual(bridge.menuActionCalls.count, 1)
    }

    func testPressHomeWhileSpotlightNeverLeavesIsAnError() {
        useWindow()
        describer.describeResults = [notesApp, spotlightHoldingAQuery]
        let response = callTool("press_home")
        XCTAssertTrue(isError(response))
        XCTAssertEqual(extractText(response),
                       "Home was pressed 3 times and Spotlight still shows. Describe the screen before the next action.")
        XCTAssertEqual(bridge.menuActionCalls.count, MirroringMenuCommand.homePressAttempts)
    }

    func testEveryMenuCommandIsHeldToTheSameCheck() {
        input.ensureConnectedResult = "paused"
        for tool in MirroringMenuCommand.allCases.map(\.toolName) {
            XCTAssertTrue(isError(callTool(tool)), tool)
        }
        XCTAssertTrue(bridge.menuActionCalls.isEmpty)
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

    private let parentScreen = [TapPoint(text: "Settings", tapX: 200, tapY: 100, confidence: 0.95),
                                TapPoint(text: "General", tapX: 200, tapY: 300, confidence: 0.95)]

    func testPressBackTapsOCRChevron() {
        // Chevron at the top of a 410x898 window — must fall inside top 15% zone (y <= 134).
        let chevron = TapPoint(text: "<", tapX: 24, tapY: 60, confidence: 0.95)
        let title = TapPoint(text: "About", tapX: 200, tapY: 60, confidence: 0.95)
        describer.describeResults = [describeResult(with: [chevron, title]), describeResult(with: parentScreen)]

        let response = callTool("press_back")
        XCTAssertFalse(isError(response))
        XCTAssertEqual(input.tapCalls.count, 1)
        XCTAssertEqual(input.tapCalls.first?.x, 24)
        XCTAssertEqual(input.tapCalls.first?.y, 60)
        XCTAssertEqual(extractText(response),
                       "Pressed back: tapped the \"<\" back chevron at (24, 60). The screen changed.")
    }

    func testPressBackFallsBackToCanonicalPositionAndSaysSo() {
        // No chevron in OCR — handler should tap the iPhone Mirroring portrait
        // fallback (xFraction=0.112, yFraction=0.135 for 410x898).
        let title = TapPoint(text: "About", tapX: 200, tapY: 60, confidence: 0.95)
        describer.describeResults = [describeResult(with: [title]), describeResult(with: parentScreen)]

        let response = callTool("press_back")
        XCTAssertFalse(isError(response))
        XCTAssertEqual(input.tapCalls.count, 1)
        let call = input.tapCalls.first!
        XCTAssertEqual(call.x, 410.0 * 0.112, accuracy: 0.001)
        XCTAssertEqual(call.y, 898.0 * 0.135, accuracy: 0.001)
        XCTAssertTrue(extractText(response)?.contains("OCR found no \"<\" chevron") ?? false,
                      extractText(response) ?? "")
    }

    /// carnet#52: a back tap that changed nothing is not reported as success.
    func testPressBackThatLeavesTheScreenUnchangedIsAnError() {
        describer.describeResult = describeResult(with: parentScreen)
        let response = callTool("press_back")
        XCTAssertTrue(isError(response))
        XCTAssertTrue(extractText(response)?.contains("the screen did not change") ?? false,
                      extractText(response) ?? "")
    }

    func testPressBackOnAScreenWithNoTextLeavesTheChangeUndecided() {
        describer.describeResult = describeResult(with: [])
        let response = callTool("press_back")
        XCTAssertFalse(isError(response), "no second back press is invited")
        XCTAssertTrue(extractText(response)?.contains("unknown") ?? false, extractText(response) ?? "")
    }

    func testPressBackOnAPausedSessionIsRefusedWithoutATap() {
        input.ensureConnectedResult = "Target 'iphone' is paused"
        let response = callTool("press_back")
        XCTAssertTrue(isError(response))
        XCTAssertEqual(extractText(response), "Target 'iphone' is paused")
        XCTAssertEqual(input.tapCalls.count, 0)
    }

    func testARefusedBackTapIsNotPassedOffAsPressed() {
        input.tapResult = "Target 'iphone' stopped accepting input"
        describer.describeResult = describeResult(with: parentScreen)
        let response = callTool("press_back")
        XCTAssertTrue(isError(response))
        XCTAssertTrue(extractText(response)?.contains("did not complete: Target 'iphone' stopped accepting input")
                      ?? false, extractText(response) ?? "")
    }

    /// On a macOS app target, press_back sends Cmd+[ and taps nothing.
    func testPressBackOnAMacTargetPressesCommandBracket() {
        let outcome = KeyboardShortcutBacktracker.cmdBracket.tapBack(
            elements: [], input: input, windowSize: CGSize(width: 800, height: 600),
            fallback: ExplorerUtilities.defaultBackButtonFallback)
        XCTAssertEqual(outcome, BackOutcome(action: .shortcut("Cmd+["), error: nil))
        XCTAssertEqual(input.tapCalls.count, 0)
        let reply = BackNavigation.verdict(outcome, before: parentScreen,
                                           after: [TapPoint(text: "Inbox", tapX: 1, tapY: 1, confidence: 1)])
        XCTAssertFalse(reply.isError)
        guard case .text(let text) = reply.content.first else { return XCTFail("a text reply") }
        XCTAssertEqual(text, "Pressed back: pressed Cmd+[. The screen changed.")
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
