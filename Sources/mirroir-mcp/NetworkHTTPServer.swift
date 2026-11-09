// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: A loopback-only HTTP/1.1 listener on Network.framework: one request per connection, then close.
// ABOUTME: Bounds what a client can hold open: a connection cap, a read deadline, and the parser's size limits.

import Foundation
import HelperLib
import Network
import os

/// Why the listener could not start.
enum HTTPServerError: LocalizedError, Equatable {
    case portInUse(UInt16)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .portInUse(let port): return "Port \(port) is in use. Pass --port."
        case .failed(let reason): return "The listener could not start: \(reason)"
        }
    }
}

/// Serves HTTP on `127.0.0.1` only. The address is fixed in the type, not a
/// parameter: the requests carry a bearer token and screen contents in clear
/// text, which is safe on loopback and nowhere else.
///
/// Requests are answered one at a time, in the order their last byte arrived.
/// A request whose client closes the connection while it waits is marked
/// abandoned, so the responder can skip work nobody is waiting for.
final class NetworkHTTPServer: HTTPServing, @unchecked Sendable {

    /// The only address the listener binds.
    static let loopbackHost = "127.0.0.1"
    /// Connections served at once; one past this is answered 503 and closed.
    static let maxConnections = 16
    /// How long a connection may take to send its whole request.
    static let readTimeout: TimeInterval = 30
    /// How long `start` waits for the listener to bind.
    static let startTimeout: TimeInterval = 5
    /// Most bytes taken from a connection in one read.
    private static let readChunkBytes = 64 * 1024

    private let requestedPort: UInt16
    private let readTimeout: TimeInterval
    private let onFailure: @Sendable (String) -> Void
    /// Accepts connections and guards `listener`, `openConnections` and every `Exchange`.
    private let queue = DispatchQueue(label: "mirroir.serve.network")
    /// Runs the responder, one request at a time in the order they completed,
    /// so a long tool call never stalls accepting or refusing other connections.
    private let responderQueue = DispatchQueue(label: "mirroir.serve.responder")
    private var listener: NWListener?
    private var openConnections = 0

    /// - Parameters:
    ///   - port: The port to bind on loopback; 0 lets the system choose a free one.
    ///   - readTimeout: How long a connection may take to send its request.
    ///   - onFailure: Called with the reason when a listener that had started stops serving.
    init(port: UInt16, readTimeout: TimeInterval = NetworkHTTPServer.readTimeout,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.requestedPort = port
        self.readTimeout = readTimeout
        self.onFailure = onFailure
    }

    var boundPort: UInt16? {
        queue.sync { listener?.port?.rawValue }
    }

    /// The address the listener is told to bind.
    static func localEndpoint(port: UInt16) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(loopbackHost), port: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    func start(responder: HTTPResponder) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = Self.localEndpoint(port: requestedPort)
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw HTTPServerError.failed(error.localizedDescription)
        }

        let ready = DispatchSemaphore(value: 0)
        let startFailure = OSAllocatedUnfairLock(initialState: NWError?.none)
        let answered = OSAllocatedUnfairLock(initialState: false)
        let onFailure = self.onFailure
        listener.stateUpdateHandler = { state in
            // A port another process holds is reported as `failed` or, on some
            // systems, as `waiting`: either way the listener is not serving.
            let failure: NWError?
            switch state {
            case .ready: failure = nil
            case .failed(let error), .waiting(let error): failure = error
            default: return
            }
            let first = answered.withLock { seen -> Bool in
                defer { seen = true }
                return !seen
            }
            if first {
                startFailure.withLock { $0 = failure }
                ready.signal()
            } else if let failure {
                // It had started, and no longer serves: the owner decides
                // what to do with a server nobody can reach.
                onFailure(failure.localizedDescription)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, responder: responder)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + Self.startTimeout) == .success else {
            listener.cancel()
            throw HTTPServerError.failed("no answer from the network stack after \(Int(Self.startTimeout)) s")
        }
        if let error = startFailure.withLock({ $0 }) {
            listener.cancel()
            if case .posix(let code) = error, code == .EADDRINUSE {
                throw HTTPServerError.portInUse(requestedPort)
            }
            throw HTTPServerError.failed(error.localizedDescription)
        }
        queue.sync { self.listener = listener }
    }

    func stop() {
        queue.sync {
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
        }
    }

    /// One connection's request as it arrives. Every field but `abandoned` is
    /// touched on `queue` only.
    private final class Exchange: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        /// The headers, parsed once when the blank line arrives.
        var head: HTTPRequestHead?
        /// The whole request is in and waits for, or has, its answer.
        var requestComplete = false
        /// Nothing more is read or answered: refused, timed out, or closed.
        var closed = false
        /// The client closed before its answer; read by the responder's thread.
        let abandoned = OSAllocatedUnfairLock(initialState: false)

        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// Runs on `queue`.
    private func accept(_ connection: NWConnection, responder: HTTPResponder) {
        let exchange = Exchange(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed:
                connection.cancel()
            case .cancelled:
                self?.openConnections -= 1
                exchange.closed = true
                exchange.abandoned.withLock { $0 = true }
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        openConnections += 1
        connection.start(queue: queue)
        guard openConnections <= Self.maxConnections else {
            finish(exchange, with: .text(503, "Too many connections."))
            return
        }
        // A connection that has not sent its request by the deadline is closed
        // without an answer: there is no request to answer. The deadline is
        // absolute, so bytes that trickle in do not extend it.
        queue.asyncAfter(deadline: .now() + readTimeout) {
            guard !exchange.requestComplete, !exchange.closed else { return }
            exchange.closed = true
            connection.cancel()
        }
        read(exchange, responder: responder)
    }

    /// Runs on `queue`. Reads until the request is whole, refused, or given up on.
    private func read(_ exchange: Exchange, responder: HTTPResponder) {
        exchange.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunkBytes) {
            [weak self] data, _, isComplete, error in
            guard let self, !exchange.closed else { return }
            if let data { exchange.buffer.append(data) }
            let peerGone = isComplete || error != nil

            if exchange.head == nil {
                switch HTTPRequestParser.head(of: exchange.buffer) {
                case .incomplete:
                    break
                case .rejected(let response):
                    return self.finish(exchange, with: response)
                case .parsed(let head):
                    // Path, method, origin and token are judged now, so a
                    // request that will be refused never has its body read.
                    if let refusal = responder.refuse(head.request(body: Data())) {
                        return self.finish(exchange, with: refusal)
                    }
                    exchange.head = head
                }
            }
            if let head = exchange.head, let body = HTTPRequestParser.body(of: head, in: exchange.buffer) {
                exchange.requestComplete = true
                exchange.buffer = Data()
                self.answer(head.request(body: body), on: exchange, responder: responder)
                if peerGone { self.abandon(exchange) } else { self.watchForClose(exchange) }
                return
            }
            if peerGone {
                exchange.closed = true
                exchange.connection.cancel()
            } else {
                self.read(exchange, responder: responder)
            }
        }
    }

    /// Runs on `queue`. Hands the request to the responder, in arrival order.
    private func answer(_ request: HTTPRequest, on exchange: Exchange, responder: HTTPResponder) {
        responderQueue.async {
            let response = responder.respond(request) { exchange.abandoned.withLock { $0 } }
            self.queue.async {
                guard !exchange.closed else { return }
                self.finish(exchange, with: response)
            }
        }
    }

    /// Runs on `queue`. While a request waits for its answer, the only thing
    /// its connection can say is that the client left. A client that closes
    /// its sending side and still waits looks the same and is treated the
    /// same: for a server that taps a phone, running a call nobody waits for
    /// is the worse mistake.
    private func watchForClose(_ exchange: Exchange) {
        exchange.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunkBytes) {
            [weak self] _, _, isComplete, error in
            guard let self, !exchange.closed else { return }
            if isComplete || error != nil {
                self.abandon(exchange)
            } else {
                self.watchForClose(exchange)
            }
        }
    }

    /// Runs on `queue`. The client left before its answer: its call is still
    /// handed to the responder in turn, which is told nobody is waiting.
    private func abandon(_ exchange: Exchange) {
        exchange.closed = true
        exchange.abandoned.withLock { $0 = true }
        exchange.connection.cancel()
    }

    /// Runs on `queue`. Writes the response and closes the connection.
    private func finish(_ exchange: Exchange, with response: HTTPResponse) {
        exchange.closed = true
        let connection = exchange.connection
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
