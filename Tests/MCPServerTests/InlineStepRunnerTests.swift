// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
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
