// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: RSD handshake tests: go-ios rsd_test.go's device handshake, sent as XPC over the full scripted stack.
// ABOUTME: Covers the service-to-port map, device properties, the .shim.remote fallback and malformed handshakes.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation
import XCTest
@testable import MirroirCoreDevice

final class RSDClientTests: XCTestCase {

    /// go-ios's `rsdOutput` (an iOS 17.0.3 handshake) converted to the XPC
    /// dictionary the device sends.
    private func handshakeBody() throws -> RemoteXPCDictionary {
        let json = try JSONSerialization.jsonObject(with: try Fixture.data("rsd_handshake", "json"))
        return try XCTUnwrap(try JSONToXPC.convert(json).dictionaryValue)
    }

    /// Replays the handshake through HTTP/2 + RemoteXPC exactly as a device
    /// would: settings, init-handshake replies, then the Handshake message.
    func testHandshakeOverTheWireParsesServicesAndProperties() throws {
        let body = try handshakeBody()
        let handshakeMessage = try DeviceScript.message(
            RemoteXPCMessage(flags: [.alwaysSet, .data], messageID: 0, body: body), stream: .clientServer)
        let transport = ScriptedTransport(
            inbound: DeviceScript.settings() + (try DeviceScript.handshakeReplies()) + handshakeMessage,
            readChunk: 1000)
        let connection = try RemoteXPCConnection.open(transport: transport)
        let handshake = try RSDClient.handshake(over: connection)

        XCTAssertEqual(handshake.udid, "00008020-0000000000000000")
        XCTAssertEqual(handshake.services.count, 67)
        XCTAssertEqual(handshake.properties["ProductType"], .string("iPhone11,6"))
        XCTAssertEqual(handshake.properties["OSVersion"], .string("17.0.3"))
        let testmanagerd = try XCTUnwrap(handshake.services["com.apple.dt.testmanagerd.remote"])
        XCTAssertEqual(testmanagerd.port, 50340)
        XCTAssertEqual(testmanagerd.entitlement, "com.apple.private.dt.testmanagerd.client")
        XCTAssertEqual(testmanagerd.properties?["UsesRemoteXPC"], .bool(false))
    }

    /// go-ios TestGetRsdPorts.
    func testPortLookupExactAndShimFallback() throws {
        let handshake = try RSDClient.parse(try handshakeBody())
        XCTAssertEqual(try handshake.port(for: "com.apple.dt.testmanagerd.remote"), 50340)
        XCTAssertEqual(try handshake.port(for: "com.apple.syslog_relay"), 50343)
        XCTAssertEqual(handshake.service(forPort: 50343), "com.apple.syslog_relay.shim.remote")
        XCTAssertNil(handshake.service(forPort: 1))
    }

    func testUnpublishedServiceIsATypedErrorNotPortZero() throws {
        // iOS 17 predates dtuhidd, so the universal HID service is absent.
        let service = "com.apple.coredevice.hid.universalhidservice"
        let handshake = try RSDClient.parse(try handshakeBody())
        XCTAssertThrowsError(try handshake.port(for: service)) { error in
            XCTAssertEqual(error as? RSDError, .serviceNotPublished(service))
        }
    }

    func testIntegerPortsAreAcceptedAndInvalidOnesRejected() throws {
        var body = try handshakeBody()
        body["Services"] = .dictionary([
            "numeric": .dictionary(["Port": .uint64(1234)]),
        ])
        XCTAssertEqual(try RSDClient.parse(body).services["numeric"]?.port, 1234)

        for invalid: RemoteXPCObject in [.string("not-a-number"), .string("0"), .string("70000"), .bool(true)] {
            body["Services"] = .dictionary(["broken": .dictionary(["Port": invalid])])
            XCTAssertThrowsError(try RSDClient.parse(body)) { error in
                XCTAssertEqual(error as? RSDError, .invalidPort(service: "broken"))
            }
        }
    }

    func testMissingUDIDWrongTypeAndMissingServicesAreRejected() throws {
        var noUDID = try handshakeBody()
        noUDID["Properties"] = .dictionary(RemoteXPCDictionary())
        XCTAssertThrowsError(try RSDClient.parse(noUDID)) { XCTAssertEqual($0 as? RSDError, .missingUDID) }

        var wrongType = try handshakeBody()
        wrongType["MessageType"] = .string("Goodbye")
        XCTAssertThrowsError(try RSDClient.parse(wrongType)) {
            XCTAssertEqual($0 as? RSDError, .unexpectedMessageType("Goodbye"))
        }

        var noServices = try handshakeBody()
        noServices["Services"] = nil
        XCTAssertThrowsError(try RSDClient.parse(noServices)) { XCTAssertEqual($0 as? RSDError, .missingServices) }
    }

    func testBodylessHandshakeMessageIsRejected() throws {
        let transport = ScriptedTransport(inbound: DeviceScript.settings() + (try DeviceScript.handshakeReplies())
            + (try DeviceScript.message(RemoteXPCMessage(flags: .alwaysSet, body: nil), stream: .clientServer)))
        let connection = try RemoteXPCConnection.open(transport: transport)
        XCTAssertThrowsError(try RSDClient.handshake(over: connection)) { error in
            XCTAssertEqual(error as? RemoteXPCError, .missingBody(stream: 1))
        }
    }
}
