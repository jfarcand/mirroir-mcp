// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: In-process HTTP server (Network.framework) that answers like WebDriverAgent for the endpoints mirroir uses.
// ABOUTME: Test fake for WebDriverAgentClient: records requests, can drop its session, fail actions, or answer in the legacy shape.

import CoreGraphics
import Foundation
import Network

/// A local stand-in for a WebDriverAgent runner, for unit tests only.
///
/// Mock policy: WebDriverAgent runs inside an XCTest runner on a physical
/// iPhone, so no CI machine can reach a real one. This fake speaks real HTTP
/// on a loopback port, so `WebDriverAgentClient`'s actual URLSession path,
/// JSON encoding, and session handling are exercised; only the device side is
/// replaced. It answers `GET /status`, `POST /session`,
/// `GET /session/{id}/window/size` and `POST /session/{id}/actions` with the
/// JSON shapes of WebDriverAgent 16.x (`FBResponsePayload`, `FBCommandStatus`),
/// including its 404 `invalid session id` error for a stale session. The
/// device-side behaviour it cannot reproduce is covered by real-device testing.
final class FakeWebDriverAgentServer: @unchecked Sendable {

    /// How `POST /session` reports the new session id.
    enum SessionShape {
        /// W3C: only `value.sessionId`, top-level `sessionId` null.
        case w3c
        /// Legacy JSON Wire: top-level `sessionId` and `status: 0`.
        case legacy
    }

    /// One request the fake received.
    struct Request: Equatable {
        let method: String
        let path: String
        let body: Data
    }

    /// An error the actions endpoint answers with instead of playing.
    struct ActionsFailure {
        let status: Int
        let error: String
        let message: String
    }

    private let queue = DispatchQueue(label: "fake.webdriveragent")
    private let lock = NSLock()
    private let listener: NWListener
    private let cancelled: DispatchSemaphore
    private static let shutdownTimeoutSeconds = 5
    private var state = State()

    private struct State {
        var viewport = CGSize(width: 390, height: 844)
        var ready = true
        var sessionShape = SessionShape.w3c
        var actionsFailure: ActionsFailure?
        var currentSession: String?
        var sessionsCreated = 0
        var requests: [Request] = []
    }

    /// Where the fake listens, e.g. `http://127.0.0.1:53124`.
    let baseURL: URL

    /// Start listening on an ephemeral loopback port.
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        self.cancelled = cancelled
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .cancelled: cancelled.signal()
            default: break
            }
        }
        // NWListener refuses to start without a connection handler, and the
        // handler cannot capture self before init completes: it reaches the
        // server through a box filled in once every property is set.
        let owner = Owner()
        listener.newConnectionHandler = { connection in
            guard let server = owner.server else { return connection.cancel() }
            server.serve(connection)
        }
        let startupTimeoutSeconds = 5
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + .seconds(startupTimeoutSeconds)) == .success,
              let port = listener.port?.rawValue,
              let url = URL(string: "http://127.0.0.1:\(port)") else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        baseURL = url
        owner.server = self
    }

    /// Weak link from the listener's connection handler to the server.
    private final class Owner: @unchecked Sendable {
        weak var server: FakeWebDriverAgentServer?
    }

    deinit {
        listener.cancel()
    }

    /// Stop listening and wait until the port is closed, so a client
    /// connecting afterwards is refused.
    func stop() {
        listener.cancel()
        _ = cancelled.wait(timeout: .now() + .seconds(Self.shutdownTimeoutSeconds))
    }

    // MARK: - Configuration and inspection

    var viewport: CGSize {
        get { lock.withLock { state.viewport } }
        set { lock.withLock { state.viewport = newValue } }
    }

    var ready: Bool {
        get { lock.withLock { state.ready } }
        set { lock.withLock { state.ready = newValue } }
    }

    var sessionShape: SessionShape {
        get { lock.withLock { state.sessionShape } }
        set { lock.withLock { state.sessionShape = newValue } }
    }

    var actionsFailure: ActionsFailure? {
        get { lock.withLock { state.actionsFailure } }
        set { lock.withLock { state.actionsFailure = newValue } }
    }

    var sessionsCreated: Int { lock.withLock { state.sessionsCreated } }

    var requests: [Request] { lock.withLock { state.requests } }

    /// Bodies of every actions request, in order.
    var actionBodies: [Data] {
        requests.filter { $0.path.hasSuffix("/actions") }.map(\.body)
    }

    /// Forget the current session, as a restarted runner does: the next
    /// request that names it gets `invalid session id`.
    func dropSession() {
        lock.withLock { state.currentSession = nil }
    }

    // MARK: - HTTP

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let receiveChunkBytes = 65_536

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                let (status, body) = self.route(request)
                self.respond(on: connection, status: status, body: body)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// A complete request in `buffer`, or nil while more bytes are needed.
    private static func parse(_ buffer: Data) -> Request? {
        guard let headerEnd = buffer.range(of: headerTerminator) else { return nil }
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        let contentLength = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else {
                return nil
            }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]),
                       body: Data(body.prefix(contentLength)))
    }

    private func respond(on connection: NWConnection, status: Int, body: [String: Any]) {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(payload.count)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routes

    private static let notFound = 404

    private func route(_ request: Request) -> (Int, [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        state.requests.append(request)
        let parts = request.path.split(separator: "/").map(String.init)

        switch (request.method, parts.count) {
        case ("GET", 1) where parts[0] == "status":
            return (200, ["sessionId": NSNull(), "value": [
                "ready": state.ready, "message": "WebDriverAgent is ready to accept commands",
                "state": "success", "os": ["name": "iOS", "version": "26.0"],
            ]])
        case ("POST", 1) where parts[0] == "session":
            state.sessionsCreated += 1
            let session = "fake-session-\(state.sessionsCreated)"
            state.currentSession = session
            switch state.sessionShape {
            case .w3c:
                return (200, ["sessionId": NSNull(),
                              "value": ["sessionId": session, "capabilities": [String: Any]()]])
            case .legacy:
                return (200, ["status": 0, "sessionId": session,
                              "value": ["capabilities": [String: Any]()]])
            }
        case (_, 3...) where parts[0] == "session":
            return sessionRoute(request, session: parts[1], command: parts[2...].joined(separator: "/"))
        default:
            return Self.error(Self.notFound, "unknown command", "Unhandled endpoint: \(request.path)")
        }
    }

    /// A request under `/session/{id}/`; the caller holds `lock`.
    private func sessionRoute(_ request: Request, session: String, command: String) -> (Int, [String: Any]) {
        guard session == state.currentSession else {
            return Self.error(Self.notFound, "invalid session id",
                              "Session does not exist")
        }
        switch (request.method, command) {
        case ("GET", "window/size"):
            return (200, ["sessionId": session, "value": [
                "width": Double(state.viewport.width), "height": Double(state.viewport.height),
            ]])
        case ("POST", "actions"):
            if let failure = state.actionsFailure {
                return Self.error(failure.status, failure.error, failure.message)
            }
            return (200, ["sessionId": session, "value": NSNull()])
        default:
            return Self.error(Self.notFound, "unknown command", "Unhandled endpoint: \(request.path)")
        }
    }

    private static func error(_ status: Int, _ code: String, _ message: String) -> (Int, [String: Any]) {
        (status, ["sessionId": NSNull(),
                  "value": ["error": code, "message": message, "traceback": ""]])
    }
}
