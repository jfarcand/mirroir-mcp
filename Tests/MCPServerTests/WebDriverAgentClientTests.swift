// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests WebDriverAgentClient over real HTTP against FakeWebDriverAgentServer, and WebDriverAgentResponse decoding.
// ABOUTME: Covers session creation and reuse, re-creation after a dropped session, typed HTTP errors, and legacy shapes.

import XCTest
import CoreGraphics
@testable import mirroir_mcp

final class WebDriverAgentClientTests: XCTestCase {

    private var server: FakeWebDriverAgentServer!
    private var client: WebDriverAgentClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try FakeWebDriverAgentServer()
        client = WebDriverAgentClient(baseURL: server.baseURL)
    }

    override func tearDown() {
        client = nil
        server = nil
        super.tearDown()
    }

    private func gesture() throws -> MultiTouchGesture {
        try MultiTouchGesture(timelines: [
            FingerTimeline(id: 1, steps: [.down(point: CGPoint(x: 50, y: 700), atMs: nil), .up(atMs: 120)]),
            FingerTimeline(id: 2, steps: [.down(point: CGPoint(x: 300, y: 300), atMs: 20),
                                          .move(to: CGPoint(x: 300, y: 100), atMs: nil, durationMs: 60),
                                          .up(atMs: nil)]),
        ], bounds: CGSize(width: 390, height: 844))
    }

    private func sessionPaths() -> [String] {
        server.requests.map { "\($0.method) \($0.path)" }
    }

    func testStatusReportsReadinessAndOS() throws {
        let status = try client.status()
        XCTAssertEqual(status, MultiTouchBackendStatus(
            ready: true, message: "WebDriverAgent is ready to accept commands", osVersion: "iOS 26.0"))
        XCTAssertEqual(server.sessionsCreated, 0, "status needs no session")
    }

    func testViewportCreatesOneSessionAndReusesIt() throws {
        server.viewport = CGSize(width: 402, height: 874)
        XCTAssertEqual(try client.viewportSize(), CGSize(width: 402, height: 874))
        XCTAssertEqual(try client.viewportSize(), CGSize(width: 402, height: 874))
        XCTAssertEqual(server.sessionsCreated, 1)
        XCTAssertEqual(sessionPaths(), [
            "POST /session",
            "GET /session/fake-session-1/window/size",
            "GET /session/fake-session-1/window/size",
        ])
        let create = try XCTUnwrap(server.requests.first)
        let capabilities = try JSONSerialization.jsonObject(with: create.body) as? [String: Any]
        XCTAssertNotNil((capabilities?["capabilities"] as? [String: Any])?["alwaysMatch"])
    }

    func testPerformPostsTheBuilderBodyAndReportsTheGesture() throws {
        let gesture = try gesture()
        let report = try client.perform(gesture)
        XCTAssertEqual(report.gesture, gesture)
        XCTAssertGreaterThanOrEqual(report.elapsedMs, 0)
        XCTAssertEqual(server.actionBodies, [try W3CActionsBuilder.body(for: gesture)])
        XCTAssertEqual(sessionPaths().last, "POST /session/fake-session-1/actions")
    }

    func testDroppedSessionIsRecreatedAndTheRequestRetried() throws {
        _ = try client.viewportSize()
        server.dropSession()
        _ = try client.perform(try gesture())
        XCTAssertEqual(server.sessionsCreated, 2)
        XCTAssertEqual(sessionPaths(), [
            "POST /session",
            "GET /session/fake-session-1/window/size",
            "POST /session/fake-session-1/actions",
            "POST /session",
            "POST /session/fake-session-2/actions",
        ])
        XCTAssertEqual(server.actionBodies.count, 2, "the refused request and its retry")
    }

    func testLegacySessionShapeIsAccepted() throws {
        server.sessionShape = .legacy
        _ = try client.perform(try gesture())
        XCTAssertEqual(sessionPaths().last, "POST /session/fake-session-1/actions")
    }

    func testActionsErrorCarriesStatusCodeAndMessage() throws {
        server.actionsFailure = FakeWebDriverAgentServer.ActionsFailure(
            status: 500, error: "unknown error", message: "Pointer Up must not be the first action")
        XCTAssertThrowsError(try client.perform(try gesture())) {
            XCTAssertEqual($0 as? WebDriverAgentError, .http(
                endpoint: "POST /session/fake-session-1/actions", status: 500,
                error: "unknown error", message: "Pointer Up must not be the first action"))
        }
        XCTAssertEqual(server.sessionsCreated, 1, "only an invalid session triggers a new one")
    }

    func testUnreachableRunnerIsATypedError() throws {
        let closedURL = server.baseURL
        server.stop()
        let orphan = WebDriverAgentClient(baseURL: closedURL)
        XCTAssertThrowsError(try orphan.status()) {
            guard case .unreachable(let url, _) = $0 as? WebDriverAgentError else {
                return XCTFail("expected unreachable, got \($0)")
            }
            XCTAssertEqual(url, closedURL.appending(path: "status").absoluteString)
            XCTAssertTrue(String(describing: $0).contains("WebDriverAgentRunner is running"))
        }
    }

    func testActionsTimeoutScalesWithTheGesture() {
        XCTAssertEqual(WebDriverAgentClient.actionsTimeout(durationMs: 0),
                       WebDriverAgentClient.actionsTimeoutMarginSeconds)
        XCTAssertEqual(WebDriverAgentClient.actionsTimeout(durationMs: 10_000),
                       10 + WebDriverAgentClient.actionsTimeoutMarginSeconds)
    }
}

final class WebDriverAgentResponseTests: XCTestCase {

    private func reply(_ json: String, status: Int = 200) throws(WebDriverAgentError) -> WebDriverAgentReply {
        try WebDriverAgentResponse.reply(from: Data(json.utf8), httpStatus: status, endpoint: "GET /x")
    }

    private func error(_ json: String, status: Int) -> WebDriverAgentError? {
        do {
            _ = try reply(json, status: status)
            return nil
        } catch {
            return error
        }
    }

    func testSessionIDFromEitherShape() throws {
        XCTAssertEqual(try WebDriverAgentResponse.sessionID(
            from: reply(#"{"value":{"sessionId":"A"},"sessionId":null}"#)), "A")
        XCTAssertEqual(try WebDriverAgentResponse.sessionID(
            from: reply(#"{"status":0,"sessionId":"B","value":{}}"#)), "B")
        XCTAssertThrowsError(try WebDriverAgentResponse.sessionID(from: reply(#"{"value":{}}"#)))
    }

    func testW3CErrorBody() {
        let stale = error(#"{"value":{"error":"invalid session id","message":"gone"}}"#, status: 404)
        XCTAssertEqual(stale, .http(endpoint: "GET /x", status: 404, error: "invalid session id",
                                    message: "gone"))
        XCTAssertTrue(stale?.isInvalidSession ?? false)
    }

    func testLegacyNoSuchSessionIsAnInvalidSession() {
        let stale = error(#"{"status":6,"value":"Session does not exist"}"#, status: 200)
        XCTAssertTrue(stale?.isInvalidSession ?? false)
        XCTAssertEqual(error(#"{"status":13,"value":"boom"}"#, status: 200),
                       .http(endpoint: "GET /x", status: 200, error: "status 13", message: "boom"))
    }

    func testNonJSONAnswers() {
        XCTAssertEqual(error("Bad Gateway", status: 502),
                       .http(endpoint: "GET /x", status: 502, error: nil, message: "Bad Gateway"))
        guard case .malformedResponse = error("<html>", status: 200) else {
            return XCTFail("a 200 that is not JSON is malformed")
        }
        XCTAssertEqual(error("{}", status: 503),
                       .http(endpoint: "GET /x", status: 503, error: nil, message: nil))
    }

    func testWindowSizeNeedsNumbers() throws {
        XCTAssertEqual(try WebDriverAgentResponse.windowSize(
            from: reply(#"{"value":{"width":844,"height":390}}"#), endpoint: "e"),
                       CGSize(width: 844, height: 390))
        XCTAssertThrowsError(try WebDriverAgentResponse.windowSize(
            from: reply(#"{"value":{"width":"wide"}}"#), endpoint: "e"))
    }

    func testStatusWithoutOSStillDecodes() throws {
        XCTAssertEqual(try WebDriverAgentResponse.status(from: reply(#"{"value":{"ready":false}}"#)),
                       MultiTouchBackendStatus(ready: false, message: nil, osVersion: nil))
        XCTAssertThrowsError(try WebDriverAgentResponse.status(from: reply(#"{"value":null}"#)))
    }
}
