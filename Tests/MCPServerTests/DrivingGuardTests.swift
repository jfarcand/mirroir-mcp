/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Tests for driving mode: the screen read before each input, the navigation refusal, and the apps that may open.
// ABOUTME: Screens are OCR reads from a drive on CarPlay (Waze, iOS 27, 2026-11-16); input and OCR are stubs.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class DrivingGuardTests: XCTestCase {

    private var input: StubInput!
    private var describer: StubDescriber!

    override func setUp() {
        super.setUp()
        input = StubInput()
        describer = StubDescriber()
        describer.describeResult = homeScreen
    }

    private func read(_ texts: [(String, Double, Double)]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: texts.map { TapPoint(text: $0.0, tapX: $0.1, tapY: $0.2, confidence: 0.9) },
            screenshotBase64: "")
    }

    /// Waze guiding a drive, 13:25.
    private var navigationScreen: ScreenDescriber.DescribeResult {
        read([("13:25", 59, 63), ("Rue de la Seve", 200, 180), ("Re-center", 80, 760),
              ("Overview", 330, 760), ("14 min • 8.4 km", 205, 840)])
    }

    /// The Home Screen the mirror showed while CarPlay ran Waze in the car, 15:49.
    private var homeScreen: ScreenDescriber.DescribeResult {
        read([("15:49", 67, 67), ("Horloge", 159, 195), ("Spotify", 249, 860), ("Waze", 341, 688),
              ("Q Rechercher", 205, 736)])
    }

    private func policy(_ driving: DrivingRules?) -> PermissionPolicy {
        PermissionPolicy(skipPermissions: true, config: nil, drivingSource: { driving })
    }

    private var driving: PermissionPolicy { policy(DrivingRules(on: true, allowedApps: ["Spotify"])) }

    private func makeServer(policy: PermissionPolicy) -> MCPServer {
        let server = MCPServer(policy: policy, transport: .stdio)
        let registry = makeTestRegistry(bridge: StubBridge(), input: input, describer: describer)
        MirroirMCP.registerTools(server: server, registry: registry, policy: policy)
        return server
    }

    private func call(_ server: MCPServer, _ tool: String,
                      _ args: [String: JSONValue]) -> (text: String, isError: Bool) {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string(tool), "arguments": .object(args)]))
        guard let response = server.handleRequest(request),
              case .object(let result) = response.result,
              case .array(let content) = result["content"],
              case .object(let first) = content.first,
              case .string(let text) = first["text"] else { return ("", false) }
        if case .bool(let isError) = result["isError"] { return (text, isError) }
        return (text, false)
    }

    // MARK: - The check

    func testANavigationScreenIsSeen() {
        XCTAssertTrue(DrivingGuard.showsNavigation(navigationScreen.elements))
        XCTAssertTrue(DrivingGuard.showsNavigation(read([("6 min • 2.1 mi", 205, 840)]).elements))
        XCTAssertFalse(DrivingGuard.showsNavigation(homeScreen.elements))
        XCTAssertFalse(DrivingGuard.showsNavigation(read([("Alarme 6 min", 100, 300)]).elements),
                       "a time alone is not navigation")
    }

    func testDrivingModeOffNeverReadsTheScreen() {
        var reads = 0
        XCTAssertNil(DrivingGuard.refusal(tool: "tap", policy: policy(nil), read: { reads += 1; return nil }))
        XCTAssertNil(DrivingGuard.refusal(tool: "tap", policy: policy(DrivingRules(on: false)),
                                          read: { reads += 1; return nil }))
        XCTAssertEqual(reads, 0)
    }

    func testReadsAndOffPhoneToolsAreNotChecked() {
        var reads = 0
        for tool in ["describe_screen", "screenshot", "save_note", "run_steps"] {
            XCTAssertNil(DrivingGuard.refusal(tool: tool, policy: driving, read: { reads += 1; return nil }), tool)
        }
        XCTAssertEqual(reads, 0)
    }

    func testAnInputIsRefusedOnNavigationAndAllowedElsewhere() {
        let refusal = DrivingGuard.refusal(tool: "tap", policy: driving, read: { self.navigationScreen })
        XCTAssertTrue(refusal?.contains("shows navigation") == true, refusal ?? "nil")
        XCTAssertTrue(refusal?.contains("No input was sent") == true, refusal ?? "nil")
        XCTAssertNil(DrivingGuard.refusal(tool: "tap", policy: driving, read: { self.homeScreen }))
    }

    func testLeavingTheNavigationScreenIsAllowed() {
        for tool in ["press_home", "launch_app"] {
            XCTAssertNil(DrivingGuard.refusal(tool: tool, policy: driving, read: { self.navigationScreen }), tool)
        }
        XCTAssertNotNil(DrivingGuard.refusal(tool: "press_key", policy: driving, read: { self.navigationScreen }))
    }

    func testAnUnreadableScreenRefusesTheInput() {
        let refusal = DrivingGuard.refusal(tool: "swipe", policy: driving, read: { nil })
        XCTAssertTrue(refusal?.contains("could not be read") == true, refusal ?? "nil")
    }

    func testAnExplorationNeverRunsWhileDriving() {
        var reads = 0
        let refusal = DrivingGuard.refusal(tool: "generate_skill", policy: driving,
                                           read: { reads += 1; return self.homeScreen })
        XCTAssertTrue(refusal?.contains("does not run while driving") == true, refusal ?? "nil")
        XCTAssertEqual(reads, 0)
    }

    // MARK: - Through the server

    func testATapOnTheNavigationScreenSendsNothing() {
        describer.describeResult = navigationScreen
        let server = makeServer(policy: driving)
        let result = call(server, "tap", ["x": .number(80), "y": .number(760)])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("shows navigation"), result.text)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    func testATapOnTheHomeScreenGoesThrough() {
        let server = makeServer(policy: driving)
        let result = call(server, "tap", ["x": .number(249), "y": .number(500)])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(input.tapCalls.count, 1)
    }

    /// carnet#83: a Dock icon carries no name, so driving mode cannot tell
    /// whether it opens a listed app.
    func testADockTapSendsNothingWhileDriving() {
        let server = makeServer(policy: driving)
        let result = call(server, "tap", ["x": .number(249), "y": .number(860)])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("lands in the Dock"), result.text)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    func testOnlyTheListedAppsOpenWhileDriving() {
        let server = makeServer(policy: driving)
        let blocked = call(server, "launch_app", ["name": .string("Instagram")])
        XCTAssertTrue(blocked.isError, blocked.text)
        XCTAssertTrue(blocked.text.contains("does not open while driving"), blocked.text)
        let byIcon = call(server, "tap", ["text": .string("Horloge")])
        XCTAssertTrue(byIcon.isError, byIcon.text)
        XCTAssertTrue(byIcon.text.contains("'Horloge' icon"), byIcon.text)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    func testAStepListChecksEachStep() {
        describer.describeResult = navigationScreen
        let server = makeServer(policy: driving)
        let result = call(server, "run_steps", ["steps": .array([.string("tap: @80,760")])])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("shows navigation"), result.text)
        XCTAssertTrue(input.tapCalls.isEmpty)
        describer.describeResult = homeScreen
        let blocked = call(server, "run_steps", ["steps": .array([.string("launch: Instagram")])])
        XCTAssertTrue(blocked.text.contains("does not open while driving"), blocked.text)
    }
}
