// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Blocking TCP ByteTransport on Network.framework's NWConnection, for tunnel and RSD endpoints.
// ABOUTME: Bridges NWConnection's callbacks to blocking reads and writes with semaphores and deadlines.

import Foundation
import Network

/// A TCP connection to a device endpoint (typically an IPv6 tunnel address),
/// exposed as a blocking `ByteTransport`.
public final class NWConnectionTransport: ByteTransport, @unchecked Sendable {
    /// Bound on connecting. go-ios uses the same 15 s: far above a healthy
    /// tunnel connect, short enough to notice a dead tunnel whose route lingers.
    public static let defaultConnectTimeout: TimeInterval = 15
    /// Bound on a single read or write. A RemoteXPC reply that has not started
    /// arriving by then will not arrive.
    public static let defaultIOTimeout: TimeInterval = 30
    /// TCP keepalive idle time, matching go-ios's one-second keepalive period.
    public static let keepaliveIdleSeconds = 1

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mirroir.coredevice.nwtransport")
    private let ioTimeout: TimeInterval
    private let lock = NSLock()
    private var closed = false

    /// Connects to `host`:`port` and blocks until the connection is ready.
    public init(host: String, port: Int,
                connectTimeout: TimeInterval = NWConnectionTransport.defaultConnectTimeout,
                ioTimeout: TimeInterval = NWConnectionTransport.defaultIOTimeout) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0,
              port <= Int(UInt16.max) else {
            throw TransportError.invalidEndpoint(host: host, port: port)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = Self.keepaliveIdleSeconds
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        self.ioTimeout = ioTimeout
        try waitUntilReady(timeout: connectTimeout)
    }

    private func waitUntilReady(timeout: TimeInterval) throws {
        let ready = DispatchSemaphore(value: 0)
        let outcome = ResultBox<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.set(.success(()))
                ready.signal()
            case .failed(let error), .waiting(let error):
                outcome.set(.failure(TransportError.failed(operation: "connect", reason: "\(error)")))
                ready.signal()
            case .cancelled:
                outcome.set(.failure(TransportError.closed))
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else {
            connection.cancel()
            throw TransportError.timedOut(operation: "connect")
        }
        connection.stateUpdateHandler = nil
        if case .failure(let error)? = outcome.value {
            connection.cancel()
            throw error
        }
    }

    public func write(_ data: Data) throws {
        try checkOpen()
        let done = DispatchSemaphore(value: 0)
        let outcome = ResultBox<Void>()
        connection.send(content: data, completion: .contentProcessed { error in
            outcome.set(error.map { .failure(TransportError.failed(operation: "write", reason: "\($0)")) }
                ?? .success(()))
            done.signal()
        })
        guard done.wait(timeout: .now() + ioTimeout) == .success else {
            throw TransportError.timedOut(operation: "write")
        }
        if case .failure(let error)? = outcome.value { throw error }
    }

    public func read(maximumLength: Int) throws -> Data {
        try checkOpen()
        let done = DispatchSemaphore(value: 0)
        let outcome = ResultBox<Data>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, isComplete, error in
            if let error {
                outcome.set(.failure(TransportError.failed(operation: "read", reason: "\(error)")))
            } else if let content, !content.isEmpty {
                outcome.set(.success(content))
            } else if isComplete {
                outcome.set(.failure(TransportError.closed))
            } else {
                outcome.set(.failure(TransportError.failed(operation: "read", reason: "empty receive")))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + ioTimeout) == .success else {
            throw TransportError.timedOut(operation: "read")
        }
        switch outcome.value {
        case .success(let data)?:
            return data
        case .failure(let error)?:
            throw error
        case nil:
            throw TransportError.closed
        }
    }

    public func close() {
        let wasOpen = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        if wasOpen { connection.cancel() }
    }

    private func checkOpen() throws {
        if lock.withLock({ closed }) { throw TransportError.closed }
    }
}

/// A lock-guarded slot a Network.framework callback fills and the blocked
/// caller reads once the semaphore fires.
final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func set(_ result: Result<Value, Error>) {
        lock.withLock {
            if stored == nil { stored = result }
        }
    }

    var value: Result<Value, Error>? {
        lock.withLock { stored }
    }
}
