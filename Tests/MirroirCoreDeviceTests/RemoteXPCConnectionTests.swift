// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: RemoteXPC connection tests: the three-message init handshake, request flags and ids, framed receives.
// ABOUTME: Runs the full HTTP/2 + XPC stack over a scripted in-memory transport and decodes what the client wrote.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation
import XCTest
@testable import MirroirCoreDevice

final class RemoteXPCConnectionTests: XCTestCase {

    /// Splits what the client wrote into (stream, XPC message) pairs, skipping
    /// set-up and HEADERS frames.
    private func sentMessages(_ written: Data) throws -> [(UInt32, RemoteXPCMessage)] {
        let setupLength = HTTP2Framer.clientPreface.count
        let reader = HTTP2Framer(transport: ScriptedTransport(inbound: Data(written.dropFirst(setupLength))))
        var result: [(UInt32, RemoteXPCMessage)] = []
        while true {
            let frame: HTTP2Frame
            do { frame = try reader.readFrame() } catch TransportError.closed { break }
            guard frame.type == .data else { continue }
            result.append((frame.streamID, try XPCWireCodec.decodeMessage(frame.payload)))
        }
        return result
    }

    private func openConnection(extra: Data = Data()) throws -> (RemoteXPCConnection, ScriptedTransport) {
        let transport = ScriptedTransport(inbound: DeviceScript.settings() + (try DeviceScript.handshakeReplies()) + extra)
        return (try RemoteXPCConnection.open(transport: transport), transport)
    }

    /// Each handshake reply is released only after the request it answers, so
    /// a client that reads before writing, or writes on the wrong stream,
    /// fails here instead of consuming replies queued up front.
    func testInitHandshakeMatchesGoIOS() throws {
        let transport = GatedTransport(initial: DeviceScript.settings(), gates: try DeviceScript.handshakeGates())
        _ = try RemoteXPCConnection.open(transport: transport)
        XCTAssertEqual(transport.remainingGates, 0)
        XCTAssertEqual(transport.outOfOrderStreams, [])
        let sent = try sentMessages(transport.written)
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[0].0, 1)
        XCTAssertEqual(sent[0].1, RemoteXPCMessage(flags: .alwaysSet, messageID: 0, body: RemoteXPCDictionary()))
        XCTAssertEqual(sent[1].0, 3)
        XCTAssertEqual(sent[1].1, RemoteXPCMessage(flags: [.initHandshake, .alwaysSet], messageID: 0, body: nil))
        XCTAssertEqual(sent[2].0, 1)
        XCTAssertEqual(sent[2].1.flags.rawValue, 0x201)
        XCTAssertNil(sent[2].1.body)
    }

    func testSendSetsAlwaysSetDataAndExtraFlagsWithGoIOSMessageID() throws {
        let (connection, transport) = try openConnection()
        try connection.send(["k": .string("v")], flags: .heartbeatRequest)
        try connection.send(nil)
        let sent = try sentMessages(transport.written).dropFirst(3).map(\.1)
        XCTAssertEqual(sent[0].flags, [.alwaysSet, .data, .heartbeatRequest])
        XCTAssertEqual(sent[0].messageID, RemoteXPCConnection.requestMessageID)
        XCTAssertEqual(sent[0].body, ["k": .string("v")])
        XCTAssertEqual(sent[1].flags, .alwaysSet)
        XCTAssertNil(sent[1].body)
    }

    func testReceivesAMessageSplitAcrossFramesOnEitherStream() throws {
        let reply = try XPCWireCodec.encodeMessage(
            RemoteXPCMessage(flags: [.alwaysSet, .data, .heartbeatReply], messageID: 1, body: ["ok": .bool(true)]))
        let split = reply.count / 2
        let extra = DeviceScript.data(reply.prefix(split), stream: .serverClient)
            + DeviceScript.data(Data(reply.dropFirst(split)), stream: .serverClient)
            + (try DeviceScript.message(RemoteXPCMessage(flags: .alwaysSet, body: ["n": .int64(5)]), stream: .clientServer))
        let (connection, _) = try openConnection(extra: extra)
        XCTAssertEqual(try connection.receiveOnClientServerStream().body, ["n": .int64(5)])
        XCTAssertEqual(try connection.receiveOnServerClientStream().body, ["ok": .bool(true)])
    }

    func testGatedTransportRefusesAReadBeforeTheRequest() throws {
        let transport = GatedTransport(initial: Data(), gates: try DeviceScript.handshakeGates())
        XCTAssertThrowsError(try transport.read(maximumLength: 1)) { error in
            XCTAssertEqual(error as? TransportError, .closed)
        }
    }

    func testHTTP2SetupFailureClosesTheTransport() {
        let transport = ScriptedTransport(inbound: DeviceScript.settings([(.maxFrameSize, 0)]))
        XCTAssertThrowsError(try RemoteXPCConnection.open(transport: transport)) { error in
            XCTAssertEqual(error as? HTTP2Error, .invalidSetting(id: HTTP2SettingID.maxFrameSize.rawValue, value: 0))
        }
        XCTAssertTrue(transport.closed)
    }

    func testHandshakeFailureClosesTheTransport() {
        let transport = ScriptedTransport(inbound: DeviceScript.settings())
        XCTAssertThrowsError(try RemoteXPCConnection.open(transport: transport))
        XCTAssertTrue(transport.closed)
    }

    func testClosedConnectionRefusesIO() throws {
        let (connection, transport) = try openConnection()
        connection.close()
        connection.close()
        XCTAssertTrue(transport.closed)
        XCTAssertThrowsError(try connection.send(nil)) { error in
            XCTAssertEqual(error as? RemoteXPCError, .connectionClosed)
        }
        XCTAssertThrowsError(try connection.receiveOnClientServerStream())
    }
}
