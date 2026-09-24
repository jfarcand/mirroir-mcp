// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Minimal UDP sink for the display service's RTP stream: bind on the tunnel address, drain, discard.
// ABOUTME: Touch is only applied while a media stream runs, so the stream must be received even though it is unused.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation
import Network

/// A UDP socket the device streams RTP video to. Every datagram is read and
/// discarded; only packet and byte counts are kept, as evidence that the
/// stream is flowing.
public final class RTPSink: @unchecked Sendable {
    /// Bound on binding the socket and on discovering the host address.
    public static let readyTimeout: TimeInterval = 5
    /// UDP port nothing listens on (discard); dialling it only makes the OS
    /// pick the local address that routes to the device. Nothing is sent.
    static let discardPort: UInt16 = 9

    private let listener: NWListener
    private let queue = DispatchQueue(label: "mirroir.coredevice.rtpsink")
    private let drain = DatagramDrain()

    /// The address the device should send to.
    public let host: String
    /// The UDP port the device should send to.
    public let port: Int

    /// Binds a UDP socket on `host` (the host's tunnel address) with an
    /// OS-assigned port, and starts draining it.
    public init(host: String) throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        parameters.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw TransportError.failed(operation: "bind", reason: "\(error)")
        }
        self.host = host
        let ready = DispatchSemaphore(value: 0)
        let outcome = ResultBox<Void>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.set(.success(()))
                ready.signal()
            case .failed(let error), .waiting(let error):
                outcome.set(.failure(TransportError.failed(operation: "bind", reason: "\(error)")))
                ready.signal()
            default:
                break
            }
        }
        let drain = self.drain
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            drain.adopt(connection, queue: queue)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + Self.readyTimeout) == .success else {
            listener.cancel()
            throw TransportError.timedOut(operation: "bind")
        }
        if case .failure(let error)? = outcome.value {
            listener.cancel()
            throw error
        }
        guard let assigned = listener.port?.rawValue else {
            listener.cancel()
            throw TransportError.failed(operation: "bind", reason: "no port assigned")
        }
        port = Int(assigned)
    }

    /// Datagrams received so far.
    public var packetCount: Int { drain.packetCount }
    /// Payload bytes received so far.
    public var byteCount: Int { drain.byteCount }

    /// Stops receiving and releases the socket.
    public func close() {
        drain.cancelAll()
        listener.cancel()
    }

    /// The host's own address on the route to `deviceAddress` (its tunnel
    /// address, for a tunnel peer). Equivalent to go-ios `hostTunnelAddress`.
    public static func hostAddress(reaching deviceAddress: String) throws -> String {
        guard let port = NWEndpoint.Port(rawValue: discardPort) else {
            throw TransportError.invalidEndpoint(host: deviceAddress, port: Int(discardPort))
        }
        let connection = NWConnection(host: NWEndpoint.Host(deviceAddress), port: port, using: .udp)
        defer { connection.cancel() }
        let ready = DispatchSemaphore(value: 0)
        let outcome = ResultBox<String>()
        connection.stateUpdateHandler = { [connection] state in
            switch state {
            case .ready:
                if case .hostPort(let host, _)? = connection.currentPath?.localEndpoint {
                    outcome.set(.success(Self.describe(host)))
                } else {
                    outcome.set(.failure(TransportError.failed(operation: "route", reason: "no local endpoint")))
                }
                ready.signal()
            case .failed(let error), .waiting(let error):
                outcome.set(.failure(TransportError.failed(operation: "route", reason: "\(error)")))
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "mirroir.coredevice.route"))
        guard ready.wait(timeout: .now() + readyTimeout) == .success else {
            throw TransportError.timedOut(operation: "route")
        }
        switch outcome.value {
        case .success(let address)?:
            return address
        case .failure(let error)?:
            throw error
        case nil:
            throw TransportError.timedOut(operation: "route")
        }
    }

    /// Renders an address without the interface scope suffix NW appends to
    /// link-local addresses, which the device cannot use.
    static func describe(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .ipv6(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}

/// Reads every datagram off each flow the listener accepts and discards it,
/// keeping only counts.
final class DatagramDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var packets = 0
    private var bytes = 0

    var packetCount: Int { lock.withLock { packets } }
    var byteCount: Int { lock.withLock { bytes } }

    func adopt(_ connection: NWConnection, queue: DispatchQueue) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(on: connection)
    }

    func cancelAll() {
        let open = lock.withLock { () -> [NWConnection] in
            defer { connections.removeAll() }
            return connections
        }
        open.forEach { $0.cancel() }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self, error == nil else { return }
            if let content {
                self.lock.withLock {
                    self.packets += 1
                    self.bytes += content.count
                }
            }
            self.receive(on: connection)
        }
    }
}
