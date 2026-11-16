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
// ABOUTME: Tests run_steps and tap(text:): a step list is checked whole before it runs, and stops at its first failure.
// ABOUTME: Uses StubInput and StubDescriber for the phone; the permission policy is the real one.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class InlineStepRunnerTests: XCTestCase {

    private var input: StubInput!
    private var describer: StubDescriber!

    override func setUp() {
        super.setUp()
        input = StubInput()
        describer = StubDescriber()
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Search", tapX: 200, tapY: 840, confidence: 0.99),
                       TapPoint(text: "Today", tapX: 60, tapY: 840, confidence: 0.99)],
            screenshotBase64: "")
    }

    private func makeServer(policy: PermissionPolicy) -> MCPServer {
        let server = MCPServer(policy: policy, transport: .stdio)
        let registry = makeTestRegistry(bridge: StubBridge(), input: input, describer: describer)
        MirroirMCP.registerRunStepsTools(server: server, registry: registry, policy: policy)
        MirroirMCP.registerInputTools(server: server, registry: registry)
        MirroirMCP.registerTapTools(server: server, registry: registry)
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

    private var allowAll: PermissionPolicy { PermissionPolicy(skipPermissions: true, config: nil) }

    private func steps(_ raw: [String]) -> [String: JSONValue] {
        ["steps": .array(raw.map { .string($0) })]
    }

    // MARK: - Running

    func testStepsRunInOrderAndTheReplyEndsWithTheScreen() {
        let result = call(makeServer(policy: allowAll), "run_steps",
                          steps(["tap: Search", "type: calculator"]))
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(input.tapCalls.map(\.x), [200])
        XCTAssertEqual(input.typeCalls, ["calculator"])
        XCTAssertTrue(result.text.contains("1. PASS tap: \"Search\""), result.text)
        XCTAssertTrue(result.text.contains("2. PASS type: \"calculator\""), result.text)
        XCTAssertTrue(result.text.hasSuffix("Screen now: Search Today"), result.text)
    }

    func testTheRunStopsAtTheFirstFailure() {
        let result = call(makeServer(policy: allowAll), "run_steps",
                          steps(["tap: Purchase", "type: never typed"]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(input.typeCalls.isEmpty)
        XCTAssertTrue(result.text.contains("1. FAIL tap: \"Purchase\""), result.text)
        XCTAssertTrue(result.text.contains("Visible: [Search, Today]"), result.text)
        XCTAssertTrue(result.text.contains("2. SKIP type: \"never typed\""), result.text)
    }

    /// A search field showing its query has no text to name it by (App Store,
    /// measured on an XR): a point is the only way to reach it from a step.
    func testATapStepCanNameAPoint() {
        let result = call(makeServer(policy: allowAll), "run_steps",
                          steps(["tap: @324,113", "type: weather"]))
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(input.tapCalls.first?.x, 324)
        XCTAssertEqual(input.tapCalls.first?.y, 113)
        XCTAssertEqual(input.typeCalls, ["weather"])
        XCTAssertEqual(describer.describeCallCount, 1, "only the final read: a point needs no OCR")
    }

    // MARK: - A tap the screen did not answer

    /// jfarcand/mirroir-mcp#84: on macOS 27.3 every tap reported PASS while
    /// the screen never moved. The reply now says when the read after a text
    /// tap matches the read it was found in.
    func testATextTapOnAnUnchangedScreenSaysSo() {
        let result = call(makeServer(policy: allowAll), "tap", ["text": .string("Search")])
        XCTAssertFalse(result.isError, "an unchanged screen is a hint, not a failure: \(result.text)")
        XCTAssertTrue(result.text.contains(
            "The screen read the same before and after tapping \"Search\""), result.text)
        XCTAssertTrue(result.text.hasSuffix("Screen now: Search Today"), result.text)
    }

    func testATextTapThatChangesTheScreenSaysNothingMore() {
        let after = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Games", tapX: 60, tapY: 100, confidence: 0.99)],
            screenshotBase64: "")
        describer.describeResults = [describer.describeResult, after]
        let result = call(makeServer(policy: allowAll), "tap", ["text": .string("Search")])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertFalse(result.text.contains("read the same"), result.text)
        XCTAssertTrue(result.text.hasSuffix("Screen now: Games"), result.text)
    }

    /// 2026-11-16, iPhone 16: an icon tap that opened nothing went unnoticed
    /// because the status bar's clock and a badge read differently after it.
    func testAClockThatTickedStillReadsAsTheSameScreen() {
        let before = [TapPoint(text: "14:03", tapX: 60, tapY: 20, confidence: 0.9),
                      TapPoint(text: "Horloge", tapX: 159, tapY: 159, confidence: 0.9),
                      TapPoint(text: "Calendrier", tapX: 251, tapY: 159, confidence: 0.9)]
        let after = [TapPoint(text: "14:04", tapX: 60, tapY: 20, confidence: 0.9),
                     TapPoint(text: "Horloge", tapX: 159, tapY: 160, confidence: 0.9),
                     TapPoint(text: "Calendrier", tapX: 251, tapY: 159, confidence: 0.9)]
        XCTAssertTrue(InlineStepRunner.readsTheSame(before, after))
        let opened = [TapPoint(text: "14:04", tapX: 60, tapY: 20, confidence: 0.9),
                      TapPoint(text: "Chronomètre", tapX: 267, tapY: 857, confidence: 0.9)]
        XCTAssertFalse(InlineStepRunner.readsTheSame(before, opened))
    }

    func testOnlyAFinalTextTapIsCompared() {
        let typed = call(makeServer(policy: allowAll), "run_steps",
                         steps(["tap: Search", "type: calculator"]))
        XCTAssertFalse(typed.text.contains("read the same"), typed.text)
        let point = call(makeServer(policy: allowAll), "run_steps", steps(["tap: @324,113"]))
        XCTAssertFalse(point.text.contains("read the same"), "a point tap has no read before it")
    }

    func testTextThatLooksLikeNumbersIsStillText() {
        XCTAssertNil(TapStepPoint.parse("12,41"))
        XCTAssertNil(TapStepPoint.parse("@12"))
        XCTAssertNil(TapStepPoint.parse("@mention,here"))
        XCTAssertEqual(TapStepPoint.parse("@ 12, 41")?.y, 41)
    }

    // MARK: - Refusing before anything runs

    func testAnUnknownStepRefusesTheWholeList() {
        let result = call(makeServer(policy: allowAll), "run_steps",
                          steps(["tap: Search", "fly: away"]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(input.tapCalls.isEmpty, "the first step must not run")
        XCTAssertTrue(result.text.hasPrefix("Step 2 \"fly: away\" is not a step"), result.text)
    }

    func testAnAIOnlyStepCannotRunInline() {
        let result = call(makeServer(policy: allowAll), "run_steps",
                          steps(["verify: the forecast shows rain"]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("needs an AI client"), result.text)
    }

    func testADeniedStepRefusesTheWholeList() {
        let policy = PermissionPolicy(skipPermissions: false,
                                      config: PermissionConfig(allow: ["run_steps", "tap"]))
        let result = call(makeServer(policy: policy), "run_steps",
                          steps(["tap: Search", "type: calculator"]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(input.tapCalls.isEmpty)
        XCTAssertTrue(result.text.hasPrefix("Step 2 type: \"calculator\" is not allowed"), result.text)
    }

    func testABlockedAppIsNeverLaunched() {
        let policy = PermissionPolicy(skipPermissions: true,
                                      config: PermissionConfig(blockedApps: ["Wallet"]))
        let refusal = InlineStepRunner.prepare(["launch: Wallet"], policy: policy)
        guard case .failure(.denied(let index, _, _)) = refusal else {
            return XCTFail("expected a denial, got \(refusal)")
        }
        XCTAssertEqual(index, 0)
    }

    /// carnet#78: steps that open an app themselves are checked for that app.
    func testStepsThatOpenABlockedAppAreRefused() {
        let policy = PermissionPolicy(skipPermissions: true,
                                      config: PermissionConfig(blockedApps: ["Safari", "Settings"]))
        for step in ["open_url: https://example.com", "set_network: wifi_off"] {
            guard case .failure(.denied(let index, _, _)) = InlineStepRunner.prepare([step], policy: policy) else {
                return XCTFail("\(step) must be refused while its app is blocked")
            }
            XCTAssertEqual(index, 0)
        }
    }

    func testAMeasureIsCheckedForTheActionItRuns() {
        let policy = PermissionPolicy(skipPermissions: false,
                                      config: PermissionConfig(allow: ["measure"]))
        let refusal = InlineStepRunner.prepare(
            ["measure: { tap: \"Search\", until: \"Results\", max: 5, name: \"search\" }"],
            policy: policy)
        guard case .failure(.denied) = refusal else {
            return XCTFail("a measured tap needs tap's permission, got \(refusal)")
        }
    }

    func testAnEmptyListIsRefused() {
        guard case .failure(.empty) = InlineStepRunner.prepare([], policy: allowAll) else {
            return XCTFail("an empty list must be refused")
        }
    }

    // MARK: - tap(text:)

    func testTapByTextTapsTheMatchedElement() {
        let result = call(makeServer(policy: allowAll), "tap", ["text": .string("search")])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(input.tapCalls.first?.x, 200)
        XCTAssertEqual(input.tapCalls.first?.y, 840)
    }

    func testATapByTextThatMissesListsWhatIsVisible() {
        let result = call(makeServer(policy: allowAll), "tap", ["text": .string("Buy")])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(input.tapCalls.isEmpty)
        XCTAssertTrue(result.text.contains("Visible: [Search, Today]"), result.text)
    }

    func testATapWithNeitherTextNorCoordinatesSaysWhatToGive() {
        let result = call(makeServer(policy: allowAll), "tap", [:])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "Missing parameters: give text (string), or x and y (numbers)")
    }
}
