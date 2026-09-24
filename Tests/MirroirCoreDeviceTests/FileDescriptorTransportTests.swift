// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: FileDescriptorTransport tests over real socket pairs: partial reads, large writes, timeouts, close.
// ABOUTME: Also runs the HTTP/2 + RemoteXPC stack over the transport against a scripted device end.

import Foundation
import XCTest
@testable import MirroirCoreDevice

final class FileDescriptorTransportTests: XCTestCase {
    private var peers: [Int32] = []

    override func tearDown() {
        for peer in peers { Darwin.close(peer) }
        peers = []
        super.tearDown()
    }

    private func makeTransport(ioTimeout: TimeInterval = 5) throws -> (FileDescriptorTransport, Int32) {
        let (local, peer) = try SocketPair.make()
        peers.append(peer)
        return (try FileDescriptorTransport(adopting: local, ioTimeout: ioTimeout), peer)
    }

    private func peerWrite(_ peer: Int32, _ bytes: [UInt8]) {
        XCTAssertEqual(Darwin.write(peer, bytes, bytes.count), bytes.count)
    }

    func testShortReadsAreReassembledByReadExactly() throws {
        let (transport, peer) = try makeTransport()
        peerWrite(peer, Array(0..<10))
        XCTAssertEqual(try transport.read(maximumLength: 4), Data([0, 1, 2, 3]))
        XCTAssertEqual(try transport.readExactly(6), Data([4, 5, 6, 7, 8, 9]))
    }

    func testLargeWriteSurvivesPartialWritesWhileThePeerDrains() throws {
        let (local, peer) = try SocketPair.make()
        let transport = try FileDescriptorTransport(adopting: local)
        let drain = SocketPeer(descriptor: peer, script: Data())
        let payload = Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try transport.write(payload)
        transport.close()
        XCTAssertEqual(try drain.receivedAfterClientCloses(), payload)
    }

    /// A timed-out read closes the transport, so nothing is left waiting to
    /// swallow bytes that arrive later, and the peer sees the connection end.
    func testReadTimeoutClosesTheTransport() throws {
        let (transport, peer) = try makeTransport(ioTimeout: 0.2)
        XCTAssertThrowsError(try transport.read(maximumLength: 1)) { error in
            XCTAssertEqual(error as? TransportError, .timedOut(operation: "read"))
        }
        XCTAssertThrowsError(try transport.read(maximumLength: 3)) { error in
            XCTAssertEqual(error as? TransportError, .closed)
        }
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(peer, &byte, 1), 0, "the peer reads end of stream")
        XCTAssertEqual(Darwin.write(peer, [1, 2, 3], 3), -1, "nothing is left to receive late bytes")
        XCTAssertEqual(errno, EPIPE)
    }

    func testCloseUnblocksAPendingReadAndIsIdempotent() throws {
        let (transport, _) = try makeTransport(ioTimeout: 30)
        let outcome = ResultBox<Data>()
        let done = DispatchSemaphore(value: 0)
        let reader = Thread {
            outcome.set(Result { try transport.read(maximumLength: 1) })
            done.signal()
        }
        reader.start()
        Thread.sleep(forTimeInterval: 0.2)
        transport.close()
        transport.close()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "close must wake the blocked read")
        guard case .failure(let error)? = outcome.value else { return XCTFail("read returned data") }
        XCTAssertEqual(error as? TransportError, .closed)
        XCTAssertThrowsError(try transport.write(Data([1]))) { XCTAssertEqual($0 as? TransportError, .closed) }
    }

    func testPeerCloseSurfacesAsClosed() throws {
        let (transport, peer) = try makeTransport()
        Darwin.close(peer)
        peers.removeAll()
        XCTAssertThrowsError(try transport.read(maximumLength: 1)) { XCTAssertEqual($0 as? TransportError, .closed) }
        XCTAssertThrowsError(try transport.write(Data([1]))) { error in
            guard case .failed(let operation, _)? = error as? TransportError else { return XCTFail("\(error)") }
            XCTAssertEqual(operation, "write", "EPIPE, not SIGPIPE")
        }
    }

    func testCloseReleasesTheDescriptor() throws {
        let (local, peer) = try SocketPair.make()
        peers.append(peer)
        let transport = try FileDescriptorTransport(adopting: local)
        transport.close()
        XCTAssertEqual(fcntl(local, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testInvalidDescriptorsAreRejected() throws {
        XCTAssertThrowsError(try FileDescriptorTransport(adopting: -1)) { error in
            XCTAssertEqual(error as? TransportError, .invalidFileDescriptor(-1))
        }
        var pipeEnds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&pipeEnds), 0)
        defer { Darwin.close(pipeEnds[1]) }
        XCTAssertThrowsError(try FileDescriptorTransport(adopting: pipeEnds[0]), "a pipe is not a socket")
        XCTAssertEqual(fcntl(pipeEnds[0], F_GETFD), -1, "a refused descriptor is closed, not leaked")
    }

    /// The full stack over a real socket: HTTP/2 set-up, the XPC init
    /// handshake and one HID report, decoded from the bytes the device end got.
    func testRemoteXPCRunsOverTheTransport() throws {
        let (local, peer) = try SocketPair.make()
        let device = SocketPeer(descriptor: peer, script: DeviceScript.settings() + (try DeviceScript.handshakeReplies()))
        let connection = try RemoteXPCConnection.open(transport: try FileDescriptorTransport(adopting: local))
        let hid = UniversalHIDConnection(connection: connection)
        try hid.sendReport(Data([7, 7]), serviceID: UniversalHIDPayload.mainTouchscreenServiceID)
        hid.close()

        let sent = try device.receivedAfterClientCloses()
        XCTAssertTrue(sent.starts(with: HTTP2Framer.clientPreface))
        let reader = HTTP2Framer(transport: ScriptedTransport(inbound: Data(sent.dropFirst(HTTP2Framer.clientPreface.count))))
        var messages: [RemoteXPCMessage] = []
        while let frame = try? reader.readFrame() {
            if frame.type == .data { messages.append(try XPCWireCodec.decodeMessage(frame.payload)) }
        }
        XCTAssertEqual(messages.count, 4, "three handshake messages, then the report")
        XCTAssertEqual(messages.last?.body,
                       UniversalHIDPayload.sendReport(Data([7, 7]), serviceID: UniversalHIDPayload.mainTouchscreenServiceID))
    }
}
