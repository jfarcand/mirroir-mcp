// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Loopback tests for the Network.framework pieces: the TCP ByteTransport and the RTP UDP sink.
// ABOUTME: Real sockets on 127.0.0.1 / ::1; a device tunnel is only a routed IPv6 address, so loopback is representative.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation
import Network
import XCTest
@testable import MirroirCoreDevice

final class NetworkTransportTests: XCTestCase {
    private let queue = DispatchQueue(label: "mirroir.coredevice.tests.loopback")
    private let readyTimeout: TimeInterval = 5

    /// A TCP listener on loopback that echoes everything it receives.
    private func startEchoListener() throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.echo(connection)
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: readyTimeout)
        return listener
    }

    private static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .idempotent)
            }
            if error == nil && !isComplete { echo(connection) }
        }
    }

    func testTCPTransportRoundTripsBytesOverLoopback() throws {
        let listener = try startEchoListener()
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port?.rawValue)
        let transport = try NWConnectionTransport(host: "127.0.0.1", port: Int(port))
        defer { transport.close() }

        let payload = Data((0..<200).map { UInt8($0) })
        try transport.write(payload)
        XCTAssertEqual(try transport.readExactly(payload.count), payload)
    }

    func testClosedTransportRefusesIO() throws {
        let listener = try startEchoListener()
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port?.rawValue)
        let transport = try NWConnectionTransport(host: "127.0.0.1", port: Int(port))
        transport.close()
        transport.close()
        XCTAssertThrowsError(try transport.write(Data([1]))) { XCTAssertEqual($0 as? TransportError, .closed) }
        XCTAssertThrowsError(try transport.read(maximumLength: 1)) { XCTAssertEqual($0 as? TransportError, .closed) }
    }

    func testConnectingToAClosedPortFails() throws {
        let listener = try startEchoListener()
        let port = try XCTUnwrap(listener.port?.rawValue)
        // Cancellation is asynchronous; connect only once the port is released.
        let cancelled = expectation(description: "listener cancelled")
        listener.stateUpdateHandler = { if case .cancelled = $0 { cancelled.fulfill() } }
        listener.cancel()
        wait(for: [cancelled], timeout: readyTimeout)
        XCTAssertThrowsError(try NWConnectionTransport(host: "127.0.0.1", port: Int(port), connectTimeout: 2))
    }

    func testInvalidPortIsRejected() {
        XCTAssertThrowsError(try NWConnectionTransport(host: "127.0.0.1", port: 0)) { error in
            XCTAssertEqual(error as? TransportError, .invalidEndpoint(host: "127.0.0.1", port: 0))
        }
    }

    func testRTPSinkDrainsDatagrams() throws {
        let sink = try RTPSink(host: "::1")
        defer { sink.close() }
        XCTAssertGreaterThan(sink.port, 0)
        XCTAssertEqual(sink.host, "::1")

        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(sink.port)))
        let sender = NWConnection(host: "::1", port: port, using: .udp)
        let ready = expectation(description: "sender ready")
        sender.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        sender.start(queue: queue)
        wait(for: [ready], timeout: readyTimeout)
        defer { sender.cancel() }

        let datagrams = 5
        let size = 100
        for _ in 0..<datagrams {
            sender.send(content: Data(count: size), completion: .idempotent)
        }
        let deadline = Date().addingTimeInterval(readyTimeout)
        while sink.packetCount < datagrams && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(sink.packetCount, datagrams)
        XCTAssertEqual(sink.byteCount, datagrams * size)
    }

    func testHostAddressOnTheRouteToLoopbackIsLoopback() throws {
        XCTAssertEqual(try RTPSink.hostAddress(reaching: "::1"), "::1")
        XCTAssertEqual(try RTPSink.hostAddress(reaching: "127.0.0.1"), "127.0.0.1")
    }
}
