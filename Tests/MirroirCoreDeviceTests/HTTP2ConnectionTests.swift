// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: HTTP/2 framer and connection tests over an in-memory transport: exact set-up bytes, streams, errors.
// ABOUTME: The set-up bytes are what golang.org/x/net/http2 emits for go-ios NewHttpConnection.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation
import XCTest
@testable import MirroirCoreDevice

final class HTTP2ConnectionTests: XCTestCase {

    /// Preface, SETTINGS {MAX_CONCURRENT_STREAMS=100, INITIAL_WINDOW_SIZE=1048576},
    /// WINDOW_UPDATE(0, 983041), then the SETTINGS ack for the server's settings.
    static let expectedSetupHex =
        "505249202a20485454502f322e300d0a0d0a534d0d0a0d0a"
        + "00000c040000000000" + "000300000064" + "000400100000"
        + "000004080000000000" + "000f0001"
        + "000000040100000000"

    func testSetupWritesGoIOSSequenceAndAcksServerSettings() throws {
        let transport = ScriptedTransport(inbound: DeviceScript.settings())
        _ = try HTTP2Connection(transport: transport)
        XCTAssertEqual(Hex.encode(transport.written), Self.expectedSetupHex)
    }

    func testSetupDoesNotAckWhenFirstFrameIsNotSettings() throws {
        let transport = ScriptedTransport(inbound: HTTP2Framer.encode(
            HTTP2Frame(type: .windowUpdate, streamID: 0, payload: Data([0, 0, 0, 1]))))
        _ = try HTTP2Connection(transport: transport)
        XCTAssertFalse(Hex.encode(transport.written).hasSuffix("000000040100000000"))
    }

    func testFirstWriteOnAStreamOpensItWithEmptyHeaders() throws {
        let transport = ScriptedTransport(inbound: DeviceScript.settings())
        let connection = try HTTP2Connection(transport: transport)
        let setupLength = transport.written.count
        try connection.write(Data([0xAA]), on: .clientServer)
        try connection.write(Data([0xBB]), on: .clientServer)
        try connection.write(Data([0xCC]), on: .serverClient)
        let written = Hex.encode(transport.written.dropFirst(setupLength))
        XCTAssertEqual(written,
                       "000000010400000001" + "000001000000000001aa" + "000001000000000001bb"
                       + "000000010400000003" + "000001000000000003cc")
    }

    func testLargeWritesAreSplitAtThePeerFrameSize() throws {
        let transport = ScriptedTransport(inbound: DeviceScript.settings())
        let connection = try HTTP2Connection(transport: transport)
        let setupLength = transport.written.count
        let payload = Data((0..<(HTTP2Framer.defaultMaxFrameSize + 10)).map { UInt8(truncatingIfNeeded: $0 * 7) })
        try connection.write(payload, on: .serverClient)

        let reader = HTTP2Framer(transport: ScriptedTransport(inbound: Data(transport.written.dropFirst(setupLength))))
        let headers = try reader.readFrame()
        XCTAssertEqual(headers.type, .headers)
        XCTAssertEqual(headers.streamID, RemoteXPCStream.serverClient.rawValue)
        let first = try reader.readFrame()
        let second = try reader.readFrame()
        XCTAssertEqual([first.type, second.type], [.data, .data])
        XCTAssertEqual([first.streamID, second.streamID],
                       [RemoteXPCStream.serverClient.rawValue, RemoteXPCStream.serverClient.rawValue])
        XCTAssertEqual(first.payload, payload.prefix(HTTP2Framer.defaultMaxFrameSize))
        XCTAssertEqual(second.payload, payload.suffix(10))
        XCTAssertEqual(first.payload + second.payload, payload)
    }

    func testPeerFrameSizeOutsideTheRFCRangeIsRejectedAtSetup() {
        let invalid: [UInt32] = [0, UInt32(HTTP2Framer.defaultMaxFrameSize - 1), UInt32(HTTP2Framer.largestFrameLength + 1)]
        for value in invalid {
            let transport = ScriptedTransport(inbound: DeviceScript.settings([(.maxFrameSize, value)]))
            XCTAssertThrowsError(try HTTP2Connection(transport: transport), "\(value)") { error in
                XCTAssertEqual(error as? HTTP2Error,
                               .invalidSetting(id: HTTP2SettingID.maxFrameSize.rawValue, value: value))
            }
        }
    }

    func testPeerFrameSizeAtTheRFCBoundsIsAccepted() throws {
        for value in [UInt32(HTTP2Framer.defaultMaxFrameSize), UInt32(HTTP2Framer.largestFrameLength)] {
            _ = try HTTP2Connection(transport: ScriptedTransport(inbound: DeviceScript.settings([(.maxFrameSize, value)])))
        }
    }

    func testMidStreamZeroFrameSizeIsRejectedBeforeAnyWriteUsesIt() throws {
        let transport = ScriptedTransport(inbound: DeviceScript.settings()
            + DeviceScript.settings([(.maxFrameSize, 0)]))
        let connection = try HTTP2Connection(transport: transport)
        XCTAssertThrowsError(try connection.read(1, from: .clientServer)) { error in
            XCTAssertEqual(error as? HTTP2Error, .invalidSetting(id: HTTP2SettingID.maxFrameSize.rawValue, value: 0))
        }
        try connection.write(Data(count: 3), on: .clientServer)
    }

    func testInitialWindowSizeAbove31BitsIsRejected() {
        let transport = ScriptedTransport(inbound: DeviceScript.settings([(.initialWindowSize, 0x8000_0000)]))
        XCTAssertThrowsError(try HTTP2Connection(transport: transport)) { error in
            XCTAssertEqual(error as? HTTP2Error,
                           .invalidSetting(id: HTTP2SettingID.initialWindowSize.rawValue, value: 0x8000_0000))
        }
    }

    /// Data for a stream nobody reads must not accumulate without bound.
    func testUnreadStreamBufferIsBounded() throws {
        let limit = 8
        let inbound = DeviceScript.settings()
            + DeviceScript.data(Data(count: 5), stream: .serverClient)
            + DeviceScript.data(Data(count: 5), stream: .serverClient)
            + DeviceScript.data(Data([1]), stream: .clientServer)
        let connection = try HTTP2Connection(transport: ScriptedTransport(inbound: inbound),
                                             maximumBufferedBytesPerStream: limit)
        XCTAssertThrowsError(try connection.read(1, from: .clientServer)) { error in
            XCTAssertEqual(error as? HTTP2Error,
                           .receiveBufferOverflow(streamID: RemoteXPCStream.serverClient.rawValue,
                                                  buffered: 10, limit: limit))
        }
    }

    func testReadsDemultiplexStreamsAndSurviveShortReads() throws {
        let inbound = DeviceScript.settings()
            + DeviceScript.data(Data([3, 3]), stream: .serverClient)
            + DeviceScript.data(Data([1, 1, 1]), stream: .clientServer)
        let connection = try HTTP2Connection(transport: ScriptedTransport(inbound: inbound, readChunk: 2))
        XCTAssertEqual(try connection.read(2, from: .clientServer), Data([1, 1]))
        XCTAssertEqual(try connection.read(2, from: .serverClient), Data([3, 3]))
        XCTAssertEqual(try connection.read(1, from: .clientServer), Data([1]))
    }

    func testMidStreamSettingsAreAcknowledgedAndOtherFramesSkipped() throws {
        let transport = ScriptedTransport(inbound: DeviceScript.settings()
            + DeviceScript.settings([(.initialWindowSize, 65_535)])
            + HTTP2Framer.encode(HTTP2Frame(type: .ping, streamID: 0, payload: Data(count: 8)))
            + HTTP2Framer.encode(HTTP2Frame(type: .settings, flags: HTTP2Flags.ack, streamID: 0))
            + DeviceScript.data(Data([9]), stream: .clientServer))
        let connection = try HTTP2Connection(transport: transport)
        let setupLength = transport.written.count
        XCTAssertEqual(try connection.read(1, from: .clientServer), Data([9]))
        XCTAssertEqual(Hex.encode(transport.written.dropFirst(setupLength)), "000000040100000000")
    }

    func testPaddedDataFramesAreUnpadded() throws {
        let padded = HTTP2Framer.encode(HTTP2Frame(
            type: .data, flags: HTTP2Flags.padded, streamID: 1, payload: Data([2, 0x41, 0x42, 0, 0])))
        let connection = try HTTP2Connection(transport: ScriptedTransport(inbound: DeviceScript.settings() + padded))
        XCTAssertEqual(try connection.read(2, from: .clientServer), Data("AB".utf8))
    }

    func testGoAwaySurfacesAsTypedError() throws {
        var payload: [UInt8] = []
        payload.appendUInt32BE(3)
        payload.appendUInt32BE(0xB)
        let goAway = HTTP2Framer.encode(HTTP2Frame(type: .goAway, streamID: 0, payload: Data(payload)))
        let connection = try HTTP2Connection(transport: ScriptedTransport(inbound: DeviceScript.settings() + goAway))
        XCTAssertThrowsError(try connection.read(1, from: .clientServer)) { error in
            XCTAssertEqual(error as? HTTP2Error, .goAway(lastStreamID: 3, errorCode: 0xB))
        }
    }

    func testStreamResetSurfacesAsTypedError() throws {
        let reset = HTTP2Framer.encode(HTTP2Frame(type: .rstStream, streamID: 1, payload: Data([0, 0, 0, 8])))
        let connection = try HTTP2Connection(transport: ScriptedTransport(inbound: DeviceScript.settings() + reset))
        XCTAssertThrowsError(try connection.read(1, from: .clientServer)) { error in
            XCTAssertEqual(error as? HTTP2Error, .streamReset(streamID: 1, errorCode: 8))
        }
    }

    func testDataOnAnUnknownStreamIsRejected() throws {
        let stray = HTTP2Framer.encode(HTTP2Frame(type: .data, streamID: 5, payload: Data([1])))
        let connection = try HTTP2Connection(transport: ScriptedTransport(inbound: DeviceScript.settings() + stray))
        XCTAssertThrowsError(try connection.read(1, from: .clientServer)) { error in
            XCTAssertEqual(error as? HTTP2Error, .unexpectedStream(5))
        }
    }

    func testPeerCloseDuringReadSurfacesAsTransportClosed() throws {
        let connection = try HTTP2Connection(transport: ScriptedTransport(inbound: DeviceScript.settings()))
        XCTAssertThrowsError(try connection.read(1, from: .clientServer)) { error in
            XCTAssertEqual(error as? TransportError, .closed)
        }
    }

    // MARK: - Framer validation

    func testOversizedFrameIsRejectedBeforeReadingItsPayload() {
        let framer = HTTP2Framer(transport: ScriptedTransport(inbound: Data([0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 1])))
        framer.maxReadFrameSize = HTTP2Framer.defaultMaxFrameSize
        XCTAssertThrowsError(try framer.readFrame()) { error in
            XCTAssertEqual(error as? HTTP2Error,
                           .frameTooLarge(length: HTTP2Framer.largestFrameLength, limit: HTTP2Framer.defaultMaxFrameSize))
        }
    }

    func testMalformedControlFramesAreRejected() {
        let cases: [HTTP2Frame] = [
            HTTP2Frame(type: .settings, streamID: 0, payload: Data(count: 5)),
            HTTP2Frame(type: .settings, flags: HTTP2Flags.ack, streamID: 0, payload: Data(count: 6)),
            HTTP2Frame(type: .windowUpdate, streamID: 0, payload: Data(count: 3)),
            HTTP2Frame(type: .rstStream, streamID: 1, payload: Data(count: 2)),
            HTTP2Frame(type: .goAway, streamID: 0, payload: Data(count: 4)),
        ]
        for frame in cases {
            let framer = HTTP2Framer(transport: ScriptedTransport(inbound: HTTP2Framer.encode(frame)))
            XCTAssertThrowsError(try framer.readFrame(), "\(frame)")
        }
    }

    func testPaddingLongerThanPayloadIsRejected() {
        let frame = HTTP2Frame(type: .data, flags: HTTP2Flags.padded, streamID: 1, payload: Data([9, 1]))
        XCTAssertThrowsError(try HTTP2Framer.dataPayload(of: frame))
    }

    func testFrameRoundTripMasksTheReservedBit() throws {
        let frame = HTTP2Frame(type: .data, flags: 0, streamID: 0xFFFF_FFFF, payload: Data([1, 2]))
        let read = try HTTP2Framer(transport: ScriptedTransport(inbound: HTTP2Framer.encode(frame))).readFrame()
        XCTAssertEqual(read.streamID, HTTP2Framer.reservedBitMask)
        XCTAssertEqual(read.payload, Data([1, 2]))
    }
}
