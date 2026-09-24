// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: HTTP client for a WebDriverAgent runner on the iPhone: status, viewport size, and W3C touch actions.
// ABOUTME: Creates one session, reuses it across gestures, and re-creates it once when WebDriverAgent drops it.

import CoreGraphics
import Foundation

/// Plays multi-finger gestures through WebDriverAgent's W3C actions endpoint.
///
/// WebDriverAgent turns every pointer source of one `POST /session/{id}/actions`
/// into one finger of a single XCTest event record and answers only after the
/// whole record has played, so a request's timeout grows with the gesture.
/// The session is created on first use with empty capabilities (it follows
/// whichever app is in the foreground), kept for later gestures, and
/// re-created once when WebDriverAgent reports it gone (the runner restarted,
/// or another client replaced it).
final class WebDriverAgentClient: MultiTouchProviding, @unchecked Sendable {
    /// Timeout for requests that answer at once (status, viewport size), in seconds.
    static let controlTimeoutSeconds: TimeInterval = 10
    /// Timeout for creating a session, in seconds: WebDriverAgent snapshots
    /// the foreground app before it answers.
    static let sessionTimeoutSeconds: TimeInterval = 60
    /// Time allowed beyond a gesture's own duration for WebDriverAgent to
    /// synthesize the events and answer, in seconds.
    static let actionsTimeoutMarginSeconds: TimeInterval = 15
    /// Milliseconds in a second.
    static let millisecondsPerSecond = 1_000.0

    /// The runner's root URL, e.g. `http://192.168.1.20:8100`.
    let baseURL: URL
    private let urlSession: URLSession
    private let lock = NSLock()
    private var sessionID: String?

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.urlSession = URLSession(configuration: .ephemeral)
    }

    deinit {
        urlSession.finishTasksAndInvalidate()
    }

    /// Timeout of the actions request for a gesture lasting `durationMs`.
    static func actionsTimeout(durationMs: Int) -> TimeInterval {
        Double(durationMs) / millisecondsPerSecond + actionsTimeoutMarginSeconds
    }

    func status() throws(WebDriverAgentError) -> MultiTouchBackendStatus {
        let reply = try send("GET", "status", body: nil, timeout: Self.controlTimeoutSeconds)
        return try WebDriverAgentResponse.status(from: reply)
    }

    func viewportSize() throws(WebDriverAgentError) -> CGSize {
        try withSession { (session: String) throws(WebDriverAgentError) -> CGSize in
            let path = "session/\(session)/window/size"
            let reply = try send("GET", path, body: nil, timeout: Self.controlTimeoutSeconds)
            return try WebDriverAgentResponse.windowSize(from: reply, endpoint: "GET /window/size")
        }
    }

    func perform(_ gesture: MultiTouchGesture) throws(WebDriverAgentError) -> MultiTouchReport {
        let body: Data
        do {
            body = try W3CActionsBuilder.body(for: gesture)
        } catch {
            throw .encodingFailed(reason: String(describing: error))
        }
        let timeout = Self.actionsTimeout(durationMs: gesture.durationMs)
        let started = DispatchTime.now()
        try withSession { (session: String) throws(WebDriverAgentError) in
            _ = try send("POST", "session/\(session)/actions", body: body, timeout: timeout)
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
        let nanosecondsPerMillisecond: UInt64 = 1_000_000
        return MultiTouchReport(gesture: gesture, elapsedMs: Int(elapsedNs / nanosecondsPerMillisecond))
    }

    // MARK: - Session

    /// Run `operation` with the current session, creating one first when
    /// there is none, and retrying once with a new session when WebDriverAgent
    /// reports the session gone.
    private func withSession<T>(
        _ operation: (String) throws(WebDriverAgentError) -> T
    ) throws(WebDriverAgentError) -> T {
        let session = try currentSession()
        do {
            return try operation(session)
        } catch where error.isInvalidSession {
            DebugLog.log("wda", "session \(session) is gone; creating a new one")
            forgetSession(session)
            return try operation(try currentSession())
        }
    }

    private func currentSession() throws(WebDriverAgentError) -> String {
        if let existing = lock.withLock({ sessionID }) { return existing }
        let created = try createSession()
        lock.withLock { sessionID = created }
        return created
    }

    private func forgetSession(_ session: String) {
        lock.withLock {
            if sessionID == session { sessionID = nil }
        }
    }

    /// `POST /session` with empty W3C capabilities.
    private func createSession() throws(WebDriverAgentError) -> String {
        let capabilities: [String: Any] = ["capabilities": ["alwaysMatch": [String: Any]()]]
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: capabilities)
        } catch {
            throw .encodingFailed(reason: String(describing: error))
        }
        let reply = try send("POST", "session", body: body, timeout: Self.sessionTimeoutSeconds)
        let session = try WebDriverAgentResponse.sessionID(from: reply)
        DebugLog.log("wda", "created session \(session) at \(baseURL.absoluteString)")
        return session
    }

    // MARK: - HTTP

    /// Holds one exchange's outcome across the completion handler.
    private final class Exchange: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: (any Error)?
    }

    /// Send one request and decode its answer, blocking until it arrives or
    /// `timeout` passes.
    private func send(_ method: String, _ path: String, body: Data?,
                      timeout: TimeInterval) throws(WebDriverAgentError) -> WebDriverAgentReply {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let exchange = Exchange()
        let done = DispatchSemaphore(value: 0)
        let task = urlSession.dataTask(with: request) { data, response, error in
            exchange.data = data
            exchange.response = response
            exchange.error = error
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw .timedOut(url: url.absoluteString, seconds: timeout)
        }

        if let error = exchange.error {
            if (error as? URLError)?.code == .timedOut {
                throw .timedOut(url: url.absoluteString, seconds: timeout)
            }
            throw .unreachable(url: url.absoluteString, reason: error.localizedDescription)
        }
        guard let http = exchange.response as? HTTPURLResponse else {
            throw .malformedResponse(endpoint: "\(method) /\(path)", reason: "not an HTTP answer")
        }
        return try WebDriverAgentResponse.reply(from: exchange.data ?? Data(),
                                                httpStatus: http.statusCode,
                                                endpoint: "\(method) /\(path)")
    }
}
