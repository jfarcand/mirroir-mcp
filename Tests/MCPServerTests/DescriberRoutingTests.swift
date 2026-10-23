// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Proves every server-internal screen check reads the local OCR describer, never the client's (vision) one.
// ABOUTME: Counts describe calls on two stub describers across launch, back, reset, network, scroll, measure, compile, start and explore.

import Foundation
import HelperLib
import XCTest
@testable import mirroir_mcp

final class DescriberRoutingTests: XCTestCase {

    private let policy = PermissionPolicy(skipPermissions: true, config: nil)

    private func screen(_ labels: String...) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: labels.enumerated().map { index, label in
                TapPoint(text: label, tapX: 200, tapY: 120 + Double(index) * 60, confidence: 0.9)
            },
            screenshotBase64: "img")
    }

    private func call(_ server: MCPServer, _ name: String, _ args: [String: JSONValue]) throws {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string(name), "arguments": .object(args)])
        )
        _ = try XCTUnwrap(server.handleRequest(request))
    }

    /// A server with `register` applied to a registry whose client describer is
    /// `client` and whose local OCR describer is `ocr`.
    private func server(
        client: StubDescriber, ocr: StubDescriber,
        register: (MCPServer, TargetRegistry) -> Void
    ) -> MCPServer {
        let server = MCPServer(policy: policy)
        let registry = makeTestRegistry(
            bridge: StubBridge(), input: StubInput(), describer: client, ocrDescriber: ocr
        )
        register(server, registry)
        return server
    }

    private func context(client: StubDescriber, ocr: StubDescriber) -> TargetContext {
        makeTestRegistry(
            bridge: StubBridge(), input: StubInput(), describer: client, ocrDescriber: ocr
        ).activeTarget
    }

    // MARK: - Tools

    func testLaunchAppConfirmsWithOCR() throws {
        let client = StubDescriber()
        let ocr = StubDescriber()
        ocr.describeResult = screen("Favorites")
        let server = server(client: client, ocr: ocr) { server, registry in
            MirroirMCP.registerNavigationTools(server: server, registry: registry, policy: self.policy)
        }

        try call(server, "launch_app", ["name": .string("Safari")])

        XCTAssertGreaterThan(ocr.describeCallCount, 0)
        XCTAssertEqual(client.describeCallCount, 0, "launch confirmation must not use the vision describer")
    }

    func testPressBackLocatesTheChevronWithOCR() throws {
        let client = StubDescriber()
        let ocr = StubDescriber()
        ocr.describeResult = screen("< Back")
        let server = server(client: client, ocr: ocr) { server, registry in
            MirroirMCP.registerNavigationTools(server: server, registry: registry, policy: self.policy)
        }

        try call(server, "press_back", [:])

        XCTAssertEqual(ocr.describeCallCount, 1)
        XCTAssertEqual(client.describeCallCount, 0, "press_back must not use the vision describer")
    }

    func testResetAppFindsTheSwitcherCardWithOCR() throws {
        let client = StubDescriber()
        let ocr = StubDescriber()
        ocr.describeResult = screen("Notes")
        let server = server(client: client, ocr: ocr) { server, registry in
            MirroirMCP.registerAppManagementTools(server: server, registry: registry)
        }

        try call(server, "reset_app", ["name": .string("Notes")])

        XCTAssertGreaterThan(ocr.describeCallCount, 0)
        XCTAssertEqual(client.describeCallCount, 0, "reset_app must not use the vision describer")
    }

    func testSetNetworkFindsTheSettingsRowWithOCR() throws {
        let client = StubDescriber()
        let ocr = StubDescriber()
        ocr.describeResult = screen("Wi-Fi")
        let server = server(client: client, ocr: ocr) { server, registry in
            MirroirMCP.registerNetworkTools(server: server, registry: registry)
        }

        try call(server, "set_network", ["mode": .string("wifi_off")])

        XCTAssertEqual(ocr.describeCallCount, 1)
        XCTAssertEqual(client.describeCallCount, 0, "set_network must not use the vision describer")
    }

    func testScrollToChecksVisibilityWithOCR() throws {
        let client = StubDescriber()
        let ocr = StubDescriber()
        ocr.describeResult = screen("About")
        let server = server(client: client, ocr: ocr) { server, registry in
            MirroirMCP.registerScrollToTools(server: server, registry: registry)
        }

        try call(server, "scroll_to", ["label": .string("About")])

        XCTAssertEqual(ocr.describeCallCount, 1)
        XCTAssertEqual(client.describeCallCount, 0, "scroll_to must not use the vision describer")
    }

    func testMeasurePollsWithOCR() throws {
        let client = StubDescriber()
        let ocr = StubDescriber()
        ocr.describeResult = screen("Go", "Done")
        let server = server(client: client, ocr: ocr) { server, registry in
            MirroirMCP.registerMeasureTools(server: server, registry: registry)
        }

        try call(server, "measure", ["action": .string("tap:Go"), "until": .string("Done")])

        XCTAssertGreaterThanOrEqual(ocr.describeCallCount, 2, "action lookup + at least one poll")
        XCTAssertEqual(client.describeCallCount, 0, "measure must not use the vision describer")
    }

    // MARK: - save_compiled

    func testSaveCompiledFingerprintsWithOCR() throws {
        let client = StubDescriber()
        let ocr = StubDescriber()
        ocr.describeResult = screen("General", "About")

        let fingerprint = MirroirMCP.captureScreenFingerprint(target: context(client: client, ocr: ocr))

        XCTAssertNotNil(fingerprint)
        XCTAssertEqual(ocr.describeCallCount, 1)
        XCTAssertEqual(client.describeCallCount, 0, "the compile fingerprint must not use the vision describer")
    }

    // MARK: - Explore launch

    func testLaunchAndWaitPollsOnlyWithOCR() {
        let client = StubDescriber()
        let ocr = StubDescriber()
        // Spotlight still up on the first poll, then the app.
        ocr.describeResults = [screen("Q Notes", "Notes"), screen("All iCloud", "New Folder")]

        let result = MirroirMCP.launchAndWait(appName: "Notes", ctx: context(client: client, ocr: ocr))

        guard case .success = result else { return XCTFail("launch should succeed") }
        XCTAssertGreaterThanOrEqual(ocr.describeCallCount, 1)
        XCTAssertEqual(client.describeCallCount, 0, "launch bookkeeping must not use the vision describer")
    }

    func testLaunchAndDescribeSpendsOneClientDescribe() {
        let client = StubDescriber()
        client.describeResult = screen("All iCloud", "New Folder")
        let ocr = StubDescriber()
        ocr.describeResult = screen("All iCloud", "New Folder")

        let result = MirroirMCP.launchAndDescribe(appName: "Notes", ctx: context(client: client, ocr: ocr))

        guard case .success = result else { return XCTFail("launch should succeed") }
        XCTAssertGreaterThanOrEqual(ocr.describeCallCount, 1)
        XCTAssertEqual(client.describeCallCount, 1, "only the first exploration screen uses the client describer")
    }

    func testLaunchInForegroundSpendsOneClientDescribe() {
        let client = StubDescriber()
        client.describeResult = screen("All iCloud", "New Folder")
        let ocr = StubDescriber()
        ocr.describeResult = screen("All iCloud", "New Folder")

        let result = MirroirMCP.launchInForeground(
            appName: "Notes", ctx: context(client: client, ocr: ocr))

        guard case .success = result else { return XCTFail("launch should succeed") }
        XCTAssertGreaterThanOrEqual(ocr.describeCallCount, 1)
        XCTAssertEqual(client.describeCallCount, 1, "only the first exploration screen uses the client describer")
    }

    func testLaunchAndDescribeReportsAnUndescribableFirstScreen() {
        let client = StubDescriber()
        let ocr = StubDescriber()
        ocr.describeResult = screen("All iCloud")

        let result = MirroirMCP.launchAndDescribe(appName: "Notes", ctx: context(client: client, ocr: ocr))

        guard case .failure(.undescribable) = result else {
            return XCTFail("a failed first describe must surface, not reuse the OCR screen")
        }
    }

    // MARK: - describe_screen settle_ms

    func testDescribeScreenForwardsSettleMs() throws {
        let client = StubDescriber()
        client.describeResult = screen("Play")
        let ocr = StubDescriber()
        let server = server(client: client, ocr: ocr) { server, registry in
            MirroirMCP.registerScreenTools(server: server, registry: registry)
        }

        try call(server, "describe_screen", ["settle_ms": .number(0)])
        XCTAssertEqual(client.lastSettleTimeoutUs, 0)

        try call(server, "describe_screen", ["settle_ms": .number(250)])
        XCTAssertEqual(client.lastSettleTimeoutUs, 250_000)

        try call(server, "describe_screen", [:])
        XCTAssertEqual(client.lastSettleTimeoutUs, EnvConfig.frameSettleTimeoutUs,
            "a client describe settles by default in every describer mode")
        XCTAssertEqual(ocr.describeCallCount, 0)
    }

    // MARK: - Already-foreground pre-check

    /// Persist a one-node graph for `appName` whose node shows `labels`.
    private func persistGraph(appName: String, labels: [String]) {
        let node = ScreenNode(
            fingerprint: "root",
            elements: labels.map { TapPoint(text: $0, tapX: 200, tapY: 120, confidence: 0.9) },
            icons: [], hints: [], depth: 0, screenType: .unknown, screenshotBase64: "",
            visitedElements: [], navBarTitle: nil, isInfiniteScroll: false,
            scrollExhausted: false, visualHash: nil
        )
        _ = GraphPersistence.save(snapshot: GraphSnapshot(
            nodes: ["root": node], edges: [], adjacency: [:], rootFingerprint: "root",
            deadEdges: [], recoveryEvents: []
        ), bundleID: appName)
    }

    /// An app name no persisted graph or APP.md uses; its graph is removed on teardown.
    private func uniqueApp() -> String {
        let name = "RoutingTest-\(UUID().uuidString)"
        addTeardownBlock { _ = GraphPersistence.delete(bundleID: name) }
        return name
    }

    func testForegroundPreCheckReadsOCRAndDescribesOnceWithClient() {
        let app = uniqueApp()
        persistGraph(appName: app, labels: ["All iCloud", "New Folder", "Notes"])
        let client = StubDescriber()
        client.describeResult = screen("All iCloud", "New Folder", "Notes")
        let ocr = StubDescriber()
        ocr.describeResult = screen("All iCloud", "New Folder", "Notes")

        let result = MirroirMCP.describeIfAlreadyForeground(
            appName: app, ctx: context(client: client, ocr: ocr), logTag: "test")

        guard case .success = result else { return XCTFail("a matching screen skips the launch") }
        XCTAssertEqual(ocr.describeCallCount, 1)
        XCTAssertEqual(client.describeCallCount, 1)
    }

    func testForegroundPreCheckWithoutGraphSpendsNoClientDescribe() {
        let client = StubDescriber()
        let ocr = StubDescriber()
        ocr.describeResult = screen("Inbox")

        XCTAssertNil(MirroirMCP.describeIfAlreadyForeground(
            appName: uniqueApp(), ctx: context(client: client, ocr: ocr), logTag: "test"))
        XCTAssertEqual(client.describeCallCount, 0)
    }

    /// generate_skill `start` for `app`, returning the input double to inspect launches.
    private func start(app: String, client: StubDescriber, ocr: StubDescriber) -> StubInput {
        let input = StubInput()
        let registry = makeTestRegistry(
            bridge: StubBridge(), input: input, describer: client, ocrDescriber: ocr)
        _ = MirroirMCP.handleStart(
            args: ["app_name": .string(app)], session: ExplorationSession(), registry: registry)
        return input
    }

    func testColdStartSpendsOneClientDescribe() {
        let client = StubDescriber()
        client.describeResult = screen("Inbox")
        let ocr = StubDescriber()
        ocr.describeResult = screen("Inbox")

        let input = start(app: uniqueApp(), client: client, ocr: ocr)

        XCTAssertEqual(input.launchAppCalls.count, 1)
        XCTAssertEqual(client.describeCallCount, 1, "pre-check and launch polls must read OCR")
    }

    func testWarmStartSkipsLaunchAndSpendsOneClientDescribe() {
        let app = uniqueApp()
        persistGraph(appName: app, labels: ["Inbox", "Mailboxes"])
        let client = StubDescriber()
        client.describeResult = screen("Inbox", "Mailboxes")
        let ocr = StubDescriber()
        ocr.describeResult = screen("Inbox", "Mailboxes")

        let input = start(app: app, client: client, ocr: ocr)

        XCTAssertTrue(input.launchAppCalls.isEmpty)
        XCTAssertEqual(client.describeCallCount, 1)
    }

    /// generate_skill `explore` for `app`. The client describer returns nil, so
    /// the handler stops right after its first-screen describe and never runs
    /// the explorer, which is enough to count the describes the launch path spends.
    private func exploreUntilFirstScreen(app: String, ocr: StubDescriber) -> (StubDescriber, StubInput) {
        let client = StubDescriber()
        let input = StubInput()
        let registry = makeTestRegistry(
            bridge: StubBridge(), input: input, describer: client, ocrDescriber: ocr)
        let result = MirroirMCP.handleExplore(
            args: ["app_name": .string(app)], session: ExplorationSession(),
            registry: registry, server: MCPServer(policy: policy), policy: policy)
        XCTAssertTrue(result.isError, "an undescribable first screen must abort the explore")
        return (client, input)
    }

    func testColdExploreSpendsOneClientDescribe() {
        let ocr = StubDescriber()
        ocr.describeResult = screen("Inbox")

        let (client, input) = exploreUntilFirstScreen(app: uniqueApp(), ocr: ocr)

        XCTAssertEqual(input.launchAppCalls.count, 1)
        XCTAssertEqual(client.describeCallCount, 1, "pre-check, launch polls and guard must read OCR")
    }

    func testWarmExploreSkipsLaunchAndSpendsOneClientDescribe() {
        let app = uniqueApp()
        persistGraph(appName: app, labels: ["Inbox", "Mailboxes"])
        let ocr = StubDescriber()
        ocr.describeResult = screen("Inbox", "Mailboxes")

        let (client, input) = exploreUntilFirstScreen(app: app, ocr: ocr)

        XCTAssertTrue(input.launchAppCalls.isEmpty)
        XCTAssertEqual(client.describeCallCount, 1)
    }
}
