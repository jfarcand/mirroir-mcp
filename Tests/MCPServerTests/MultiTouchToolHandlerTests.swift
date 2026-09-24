// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the multi_touch MCP tool: argument parsing, setup errors, held-touch refusal, and mapping.
// ABOUTME: Uses a recording MultiTouchProviding stub, plus one run end-to-end through FakeWebDriverAgentServer.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

/// Records what the playback asks of its backend. Mock policy: stands in for
/// a WebDriverAgent runner on a physical iPhone, which CI cannot reach; the
/// real client is covered over HTTP by WebDriverAgentClientTests.
final class RecordingMultiTouchProvider: MultiTouchProviding, @unchecked Sendable {
    var statusResult = MultiTouchBackendStatus(ready: true, message: nil, osVersion: "iOS 26.0")
    var viewport = CGSize(width: 390, height: 844)
    var performError: WebDriverAgentError?
    private(set) var performed: [MultiTouchGesture] = []
    private(set) var statusCalls = 0

    func status() throws(WebDriverAgentError) -> MultiTouchBackendStatus {
        statusCalls += 1
        return statusResult
    }

    func viewportSize() throws(WebDriverAgentError) -> CGSize { viewport }

    func perform(_ gesture: MultiTouchGesture) throws(WebDriverAgentError) -> MultiTouchReport {
        if let performError { throw performError }
        performed.append(gesture)
        return MultiTouchReport(gesture: gesture, elapsedMs: gesture.durationMs)
    }
}

/// The URLs the playback asked for a backend, and the provider it got.
final class ProviderFactory: @unchecked Sendable {
    let provider = RecordingMultiTouchProvider()
    private(set) var urls: [URL] = []

    func make(_ url: URL) -> any MultiTouchProviding {
        urls.append(url)
        return provider
    }
}

final class MultiTouchToolHandlerTests: XCTestCase {

    private var server: MCPServer!
    private var bridge: StubBridge!
    private var session: TouchSession!
    private var factory: ProviderFactory!
    private var configuredURL = "http://192.0.2.10:8100"

    override func setUp() {
        super.setUp()
        bridge = StubBridge()
        session = TouchSession(poster: RecordingTouchPoster())
        factory = ProviderFactory()
        register(configured: configuredURL)
    }

    override func tearDown() {
        _ = session.cancel()
        super.tearDown()
    }

    private func register(configured: String, makeProvider: (@Sendable (URL) -> any MultiTouchProviding)? = nil) {
        server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil))
        let factory = self.factory!
        let playback = MultiTouchPlayback(
            touchSession: session, configuredURL: { configured },
            makeProvider: makeProvider ?? { factory.make($0) })
        MirroirMCP.registerMultiTouchTools(
            server: server, registry: makeTestRegistry(bridge: bridge, input: StubInput()),
            playback: playback)
    }

    private func call(_ args: [String: JSONValue]) -> (text: String, isError: Bool) {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string("multi_touch"), "arguments": .object(args)]))
        guard let response = server.handleRequest(request),
              case .object(let result) = response.result,
              case .array(let content) = result["content"],
              case .object(let first) = content.first,
              case .string(let text) = first["text"] else { return ("", false) }
        if case .bool(let isError) = result["isError"] { return (text, isError) }
        return (text, false)
    }

    private func step(_ action: String, _ fields: [String: Double] = [:]) -> JSONValue {
        var object: [String: JSONValue] = ["action": .string(action)]
        for (key, value) in fields { object[key] = .number(value) }
        return .object(object)
    }

    private func finger(_ id: Int, _ steps: [JSONValue]) -> JSONValue {
        .object(["id": .number(Double(id)), "steps": .array(steps)])
    }

    /// A joystick held for 500ms while a second finger taps, in window points.
    private func joystickAndTap() -> [String: JSONValue] {
        ["fingers": .array([
            finger(1, [step("down", ["x": 41, "y": 449]),
                       step("move", ["x": 82, "y": 449, "duration_ms": 200]),
                       step("up", ["at_ms": 500])]),
            finger(2, [step("down", ["x": 205, "y": 898, "at_ms": 100]),
                       step("up", ["at_ms": 180])]),
        ])]
    }

    // MARK: - Playback

    func testFingersAreMappedFromWindowToDevicePoints() throws {
        let result = call(joystickAndTap())
        XCTAssertFalse(result.isError, result.text)
        let gesture = try XCTUnwrap(factory.provider.performed.first)
        XCTAssertEqual(gesture.paths, [
            FingerPath(id: 1, downPoint: CGPoint(x: 39, y: 422), downMs: 0,
                       moves: [FingerMove(to: CGPoint(x: 78, y: 422), startMs: 0, durationMs: 200)],
                       upMs: 500),
            FingerPath(id: 2, downPoint: CGPoint(x: 195, y: 844), downMs: 100, moves: [], upMs: 180),
        ])
        XCTAssertEqual(factory.urls, [URL(string: configuredURL)])
        XCTAssertTrue(result.text.contains("Played 2 finger(s) over 500ms"), result.text)
        XCTAssertTrue(result.text.contains("(iOS 26.0)"), result.text)
        XCTAssertTrue(result.text.contains("finger 1: down (39, 422) @0ms, move to (78, 422) 0-200ms, up @500ms"),
                      result.text)
    }

    func testBackendIsReusedAndStatusAskedOnce() {
        XCTAssertFalse(call(joystickAndTap()).isError)
        XCTAssertFalse(call(joystickAndTap()).isError)
        XCTAssertEqual(factory.urls.count, 1)
        XCTAssertEqual(factory.provider.statusCalls, 1)
        XCTAssertEqual(factory.provider.performed.count, 2)
    }

    func testWdaURLArgumentOverridesTheConfiguredOne() {
        var args = joystickAndTap()
        args["wda_url"] = .string("http://10.0.0.7:8100")
        XCTAssertFalse(call(args).isError)
        XCTAssertEqual(factory.urls, [URL(string: "http://10.0.0.7:8100")])
    }

    // MARK: - Refusals

    func testUnconfiguredRunnerExplainsTheSetup() {
        register(configured: "")
        let result = call(joystickAndTap())
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("MIRROIR_WDA_URL"), result.text)
        XCTAssertTrue(result.text.contains("docs/tools.md#multi-finger-touches-on-ios-26-webdriveragent"))
        XCTAssertTrue(factory.urls.isEmpty)
    }

    func testInvalidURLIsRefused() {
        register(configured: "ftp://phone")
        XCTAssertTrue(call(joystickAndTap()).text.contains("'ftp://phone' is not a WebDriverAgent URL"))
        register(configured: "http://")
        XCTAssertTrue(call(joystickAndTap()).isError)
        XCTAssertTrue(factory.urls.isEmpty)
    }

    func testRefusedWhileATouchIsHeld() throws {
        _ = session.begin(at: CGPoint(x: 10, y: 20), window: try XCTUnwrap(bridge.windowInfo),
                          targetPID: nil, restorePoint: nil)
        let result = call(joystickAndTap())
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("so multi_touch is refused"), result.text)
        XCTAssertTrue(result.text.contains("touch(action:\"cancel\")"), result.text)
        XCTAssertTrue(factory.urls.isEmpty, "nothing reaches the backend while a touch is held")
    }

    func testMissingWindowIsRefused() {
        bridge.windowInfo = nil
        XCTAssertTrue(call(joystickAndTap()).text.contains("window not found"))
    }

    func testCoordinatesAreCheckedAgainstTheWindow() {
        let result = call(["fingers": .array([
            finger(1, [step("down", ["x": 411, "y": 10]), step("up", ["at_ms": 50])]),
        ])])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("(411, 10) is outside the 410x898 screen"), result.text)
        XCTAssertTrue(factory.provider.performed.isEmpty)
    }

    func testRunnerThatIsNotReadyIsRefused() {
        factory.provider.statusResult = MultiTouchBackendStatus(ready: false, message: "busy", osVersion: nil)
        XCTAssertEqual(call(joystickAndTap()).text, "WebDriverAgent is running but not ready: busy")
    }

    func testBackendErrorsSurfaceWithTheirStatus() {
        factory.provider.performError = .http(endpoint: "POST /session/s/actions", status: 500,
                                              error: "unknown error", message: "boom")
        XCTAssertEqual(call(joystickAndTap()).text,
                       "WebDriverAgent POST /session/s/actions failed (HTTP 500 unknown error): boom")
    }

    func testOrientationMismatchIsRefused() {
        factory.provider.viewport = CGSize(width: 844, height: 390)
        XCTAssertTrue(call(joystickAndTap()).text.contains("landscape viewport"))
        XCTAssertTrue(factory.provider.performed.isEmpty)
    }

    // MARK: - Argument parsing

    func testArgumentErrors() {
        XCTAssertTrue(call([:]).text.contains("Missing required parameter: fingers"))
        XCTAssertTrue(call(["fingers": .array([.object(["steps": .array([])])])]).text
            .contains("fingers[0] needs an integer id"))
        XCTAssertTrue(call(["fingers": .array([.object(["id": .number(1)])])]).text
            .contains("finger 1 needs steps"))
        XCTAssertTrue(call(["fingers": .array([finger(1, [step("press")])])]).text
            .contains("finger 1 step 0 needs an action: one of down, move, up"))
        XCTAssertTrue(call(["fingers": .array([finger(1, [step("down")])])]).text
            .contains("finger 1 step 0: down needs x and y"))
        XCTAssertTrue(call(["fingers": .array([finger(1, [step("down", ["x": 1, "y": 1]),
                                                         step("move", ["x": 2, "y": 2])])])]).text
            .contains("move needs duration_ms"))
        XCTAssertTrue(call(["fingers": .array([finger(1, [
            .object(["action": .string("up"), "at_ms": .string("soon")]),
        ])])]).text.contains("at_ms must be an integer"))
        XCTAssertTrue(factory.urls.isEmpty)
    }

    func testTimelineRulesReachTheCaller() {
        let result = call(["fingers": .array([finger(1, [step("down", ["x": 1, "y": 1])])])])
        XCTAssertTrue(result.text.contains("finger 1 must end with an up step"), result.text)
    }

    // MARK: - End to end over HTTP

    func testPlaysThroughWebDriverAgentOverHTTP() throws {
        let runner = try FakeWebDriverAgentServer()
        register(configured: runner.baseURL.absoluteString,
                 makeProvider: { WebDriverAgentClient(baseURL: $0) })
        let result = call(joystickAndTap())
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(runner.requests.map { "\($0.method) \($0.path)" }, [
            "GET /status",
            "POST /session",
            "GET /session/fake-session-1/window/size",
            "POST /session/fake-session-1/actions",
        ])
        let body = try XCTUnwrap(runner.actionBodies.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sources = try XCTUnwrap(json["actions"] as? [[String: Any]])
        XCTAssertEqual(sources.map { $0["id"] as? String }, ["finger1", "finger2"])
        let second = try XCTUnwrap(sources[1]["actions"] as? [[String: Any]])
        XCTAssertEqual(second.first?["type"] as? String, "pause")
        XCTAssertEqual(second.first?["duration"] as? Int, 100)
        XCTAssertEqual(second[1]["x"] as? Double, 195)
        XCTAssertEqual(second[1]["y"] as? Double, 844)
    }
}
