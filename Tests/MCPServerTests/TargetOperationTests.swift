// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the per-target operation set and the wording of the refusal a target without one gives.
// ABOUTME: Also checks that every operation is a real tool, and that the eight tools refuse on a Mac-window target without sending anything.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class TargetOperationTests: XCTestCase {

    func testIPhoneProfileSupportsEveryOperation() {
        for operation in TargetOperation.allCases {
            XCTAssertTrue(IPhoneMirroringTarget.profile.supports(operation), operation.rawValue)
        }
        XCTAssertEqual(IPhoneMirroringTarget.profile.unsupportedOperations, [])
    }

    func testMacOSProfileSupportsNoDeviceOperation() {
        for operation in TargetOperation.allCases {
            XCTAssertFalse(MacOSAppTarget.profile.supports(operation), operation.rawValue)
        }
        XCTAssertEqual(MacOSAppTarget.profile.unsupportedOperations.map(\.rawValue),
                       ["launch_app", "open_url", "press_app_switcher", "press_home",
                        "reset_app", "set_network", "shake", "spotlight"])
    }

    func testRefusalNamesToolTargetKindReasonAndWhereItWorks() {
        XCTAssertEqual(
            MacOSAppTarget.profile.refusal(of: .shake, targetName: "telegram", supportedOn: ["iphone"]),
            "shake is unsupported on target 'telegram' (macOS App): it sends the iOS shake shortcut "
            + "(Ctrl+Cmd+Z), which this app would take as a shortcut of its own. Nothing was sent. "
            + "Supported on: iphone.")
        XCTAssertNil(IPhoneMirroringTarget.profile.refusal(
            of: .shake, targetName: "iphone", supportedOn: ["iphone"]))
    }

    func testRefusalWithNoSupportingTarget() throws {
        let refusal = try XCTUnwrap(MacOSAppTarget.profile.refusal(
            of: .pressHome, targetName: "telegram", supportedOn: []))
        XCTAssertTrue(refusal.hasSuffix("Nothing was sent. No configured target supports it."), refusal)
    }

    func testEveryOperationIsARegisteredTool() {
        let catalog = OperatingManualTests.registeredCatalog()
        XCTAssertGreaterThan(catalog.count, 30, "the catalog must hold the registered tools")
        for operation in TargetOperation.allCases {
            XCTAssertNotNil(catalog[operation.rawValue], operation.rawValue)
        }
    }

    func testStepsMapToTheirOperation() {
        XCTAssertEqual(TargetOperation(step: .home), .pressHome)
        XCTAssertEqual(TargetOperation(step: .launch(appName: "Clock")), .launchApp)
        XCTAssertEqual(TargetOperation(step: .openURL(url: "https://example.com")), .openURL)
        XCTAssertEqual(TargetOperation(step: .shake), .shake)
        XCTAssertEqual(TargetOperation(step: .resetApp(appName: "Clock")), .resetApp)
        XCTAssertEqual(TargetOperation(step: .setNetwork(mode: "wifi_off")), .setNetwork)
        XCTAssertNil(TargetOperation(step: .tap(label: "OK")))
        XCTAssertNil(TargetOperation(step: .type(text: "a")))
    }
}

/// The eight iPhone-only tools, called on a Mac-window target.
final class UnsupportedOperationToolTests: XCTestCase {

    private var server: MCPServer!
    private var registry: TargetRegistry!
    private var macInput: StubInput!
    private var phoneInput: StubInput!

    /// Arguments that would let each tool run if the target had it.
    private static let calls: [(tool: String, args: [String: JSONValue])] = [
        ("launch_app", ["name": .string("Clock")]),
        ("open_url", ["url": .string("https://example.com")]),
        ("press_home", [:]),
        ("press_app_switcher", [:]),
        ("spotlight", [:]),
        ("reset_app", ["name": .string("Clock")]),
        ("set_network", ["mode": .string("wifi_off")]),
        ("shake", [:]),
    ]

    override func setUp() {
        super.setUp()
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        server = MCPServer(policy: policy, transport: .stdio)
        macInput = StubInput()
        phoneInput = StubInput()
        let phoneBridge = StubBridge()
        phoneBridge.targetName = "iphone"
        let macBridge = StubBridge()
        macBridge.targetName = "telegram"
        // The Mac target's bridge can press menus, as the iPhone's can: what
        // refuses is the target's declared operations, not a missing method.
        let phone = TargetContext(
            name: "iphone", targetType: IPhoneMirroringTarget.configTypeName, bundleID: nil,
            bridge: phoneBridge, input: phoneInput,
            capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder())
        let mac = TargetContext(
            name: "telegram", targetType: MacOSAppTarget.configTypeName, bundleID: nil,
            bridge: macBridge, input: macInput,
            capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder())
        registry = TargetRegistry(targets: ["iphone": phone, "telegram": mac], defaultName: "telegram")
        MirroirMCP.registerTools(server: server, registry: registry, policy: policy)
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> (text: String, isError: Bool) {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string(name), "arguments": .object(args)]))
        guard case .object(let result)? = server.handleRequest(request)?.result,
              case .array(let content)? = result["content"],
              case .object(let first)? = content.first,
              case .string(let text)? = first["text"] else { return ("", true) }
        if case .bool(let isError)? = result["isError"] { return (text, isError) }
        return (text, false)
    }

    func testEachDeviceToolRefusesOnAMacTarget() {
        XCTAssertEqual(Set(Self.calls.map(\.tool)), Set(TargetOperation.allCases.map(\.rawValue)))
        for (tool, args) in Self.calls {
            let reply = call(tool, args)
            XCTAssertTrue(reply.isError, tool)
            XCTAssertTrue(reply.text.hasPrefix("\(tool) is unsupported on target 'telegram' (macOS App):"),
                          "\(tool): \(reply.text)")
            XCTAssertTrue(reply.text.hasSuffix("Nothing was sent. Supported on: iphone."),
                          "\(tool): \(reply.text)")
        }
    }

    /// `measure` launches through the same iPhone Spotlight as launch_app.
    func testMeasureRefusesALaunchActionOnAMacTarget() {
        let reply = call("measure", ["action": .string("launch: Weather"), "until": .string("Montréal")])
        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.hasPrefix("launch_app is unsupported on target 'telegram' (macOS App):"), reply.text)
        XCTAssertTrue(macInput.launchAppCalls.isEmpty)
    }

    func testNothingReachesTheMacTargetsInput() {
        for (tool, args) in Self.calls { _ = call(tool, args) }
        XCTAssertEqual(macInput.shakeCalls, 0, "shake would post Ctrl+Cmd+Z into the Mac app")
        XCTAssertEqual(macInput.launchAppCalls, [])
        XCTAssertEqual(macInput.openURLCalls, [])
        XCTAssertEqual(macInput.typeCalls, [])
        XCTAssertTrue(macInput.tapCalls.isEmpty)
    }

    func testTheTargetArgumentSelectsTheTargetThatIsChecked() {
        let reply = call("shake", ["target": .string("iphone")])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertEqual(phoneInput.shakeCalls, 1)
        XCTAssertEqual(macInput.shakeCalls, 0)
    }

    func testDeviceToolsStillRunOnTheIPhoneTarget() {
        XCTAssertTrue(registry.switchActive(to: "iphone"))
        XCTAssertFalse(call("launch_app", ["name": .string("Clock")]).isError)
        XCTAssertEqual(phoneInput.launchAppCalls, ["Clock"])
        XCTAssertFalse(call("press_home", [:]).isError)
    }
}
