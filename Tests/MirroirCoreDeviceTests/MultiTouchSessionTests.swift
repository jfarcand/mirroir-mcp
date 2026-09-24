// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: UniversalHID payload and MultiTouchSession tests with a recording report sender.
// ABOUTME: Pins the XPC payload shape and proves a session never leaves a contact down.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation
import XCTest
@testable import MirroirCoreDevice

final class MultiTouchSessionTests: XCTestCase {
    private var clock: UInt64 = 0

    private func makeSession(_ sender: RecordingHIDSender) -> MultiTouchSession {
        MultiTouchSession(sender: sender) { [unowned self] in
            clock += 1
            return clock
        }
    }

    /// Decodes the (identifier, touching, x, y) tuples a report describes.
    private func contacts(in report: Data) -> [TouchContact] {
        let bytes = [UInt8](report)
        return (0..<Int(bytes[1])).map { slot in
            let base = 3 + slot * 5
            return TouchContact(identifier: bytes[base] & 0x1F, touching: bytes[base] & 0x40 != 0,
                                x: UInt16(bytes[base + 1]) | UInt16(bytes[base + 2]) << 8,
                                y: UInt16(bytes[base + 3]) | UInt16(bytes[base + 4]) << 8)
        }
    }

    // MARK: - Payload

    /// go-ios TestSendReportPayload: the report crosses as XPC data, the
    /// service id as uint64, through the real codec.
    func testSendReportPayloadShapeSurvivesTheCodec() throws {
        let report = try TouchscreenReport.build(
            contacts: [TouchContact(identifier: 2, touching: true, x: 42, y: 43)], timestamp: 1)
        let payload = UniversalHIDPayload.sendReport(report, serviceID: UniversalHIDPayload.mainTouchscreenServiceID)
        let body = try XCTUnwrap(try XPCWireCodec.decodeMessage(
            try XPCWireCodec.encodeMessage(RemoteXPCMessage(flags: [.alwaysSet, .data], body: payload))).body)

        XCTAssertEqual(body["featureIdentifier"], .string("com.apple.coredevice.feature.remote.universalhidservice"))
        XCTAssertEqual(body["messageType"], .string("Request"))
        let send = try XCTUnwrap(body["payload"]?.dictionaryValue?["send"]?.dictionaryValue)
        XCTAssertEqual(send["_0"], .data(report))
        XCTAssertEqual(send["_1"], .uint64(257))
    }

    func testUniversalHIDConnectionSendsWithHeartbeatFlag() throws {
        let transport = ScriptedTransport(inbound: DeviceScript.settings() + (try DeviceScript.handshakeReplies()))
        let hid = UniversalHIDConnection(connection: try RemoteXPCConnection.open(transport: transport))
        let before = transport.written.count
        try hid.sendReport(Data([9]), serviceID: 257)

        let reader = HTTP2Framer(transport: ScriptedTransport(inbound: Data(transport.written.dropFirst(before))))
        let message = try XPCWireCodec.decodeMessage(try reader.readFrame().payload)
        XCTAssertEqual(message.flags, [.alwaysSet, .data, .heartbeatRequest])
        XCTAssertEqual(message.body, UniversalHIDPayload.sendReport(Data([9]), serviceID: 257))
        hid.close()
        XCTAssertTrue(transport.closed)
    }

    // MARK: - Session

    func testDownMoveLiftEmitsCompleteReports() throws {
        let sender = RecordingHIDSender()
        let session = makeSession(sender)
        try session.down(identifier: 0, x: 100, y: 200)
        try session.down(identifier: 1, x: 300, y: 400)
        try session.move(identifier: 0, x: 110, y: 210)
        try session.lift(identifier: 0)
        try session.lift(identifier: 1)

        let reports = sender.sent.map { contacts(in: $0.report) }
        XCTAssertEqual(reports, [
            [TouchContact(identifier: 0, touching: true, x: 100, y: 200)],
            [TouchContact(identifier: 0, touching: true, x: 100, y: 200),
             TouchContact(identifier: 1, touching: true, x: 300, y: 400)],
            [TouchContact(identifier: 0, touching: true, x: 110, y: 210),
             TouchContact(identifier: 1, touching: true, x: 300, y: 400)],
            [TouchContact(identifier: 0, touching: false, x: 110, y: 210),
             TouchContact(identifier: 1, touching: true, x: 300, y: 400)],
            [TouchContact(identifier: 1, touching: false, x: 300, y: 400)],
        ])
        XCTAssertTrue(sender.sent.allSatisfy { $0.serviceID == UniversalHIDPayload.mainTouchscreenServiceID })
        XCTAssertEqual(session.heldIdentifiers, [])
    }

    func testTimestampsComeFromTheInjectedMonotonicClock() throws {
        let sender = RecordingHIDSender()
        let session = makeSession(sender)
        try session.down(identifier: 0, x: 1, y: 1)
        try session.move(identifier: 0, x: 2, y: 2)
        let stamps = sender.sent.map { $0.report[45] }
        XCTAssertEqual(stamps, [1, 2])
    }

    func testCloseLiftsEveryHeldContactThenClosesTheSender() throws {
        let sender = RecordingHIDSender()
        let session = makeSession(sender)
        try session.down(identifier: 3, x: 5, y: 6)
        try session.down(identifier: 4, x: 7, y: 8)
        try session.close()
        try session.close()

        let last = try XCTUnwrap(sender.sent.last)
        XCTAssertEqual(contacts(in: last.report), [
            TouchContact(identifier: 3, touching: false, x: 5, y: 6),
            TouchContact(identifier: 4, touching: false, x: 7, y: 8),
        ])
        XCTAssertEqual(sender.closeCount, 1, "close is idempotent")
        XCTAssertThrowsError(try session.down(identifier: 0, x: 0, y: 0)) { error in
            XCTAssertEqual(error as? MultiTouchSessionError, .closed)
        }
    }

    func testLiftAllInOneReport() throws {
        let sender = RecordingHIDSender()
        let session = makeSession(sender)
        try session.down(identifier: 0, x: 1, y: 1)
        try session.down(identifier: 1, x: 2, y: 2)
        try session.liftAll()
        try session.liftAll()
        XCTAssertEqual(sender.sent.count, 3, "a second liftAll with nothing down sends nothing")
        XCTAssertTrue(contacts(in: sender.sent[2].report).allSatisfy { !$0.touching })
    }

    func testStrayLiftSendsNothing() throws {
        let sender = RecordingHIDSender()
        try makeSession(sender).lift(identifier: 2)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testProtocolMisuseIsATypedErrorAndSendsNothing() throws {
        let sender = RecordingHIDSender()
        let session = makeSession(sender)
        try session.down(identifier: 0, x: 0, y: 0)
        XCTAssertThrowsError(try session.down(identifier: 0, x: 1, y: 1)) {
            XCTAssertEqual($0 as? MultiTouchSessionError, .contactAlreadyDown(0))
        }
        XCTAssertThrowsError(try session.move(identifier: 1, x: 1, y: 1)) {
            XCTAssertEqual($0 as? MultiTouchSessionError, .contactNotDown(1))
        }
        XCTAssertThrowsError(try session.down(identifier: 9, x: 1, y: 1)) {
            XCTAssertEqual($0 as? TouchReportError, .contactIdentifierOutOfRange(identifier: 9, maximum: 4))
        }
        XCTAssertEqual(sender.sent.count, 1)
        XCTAssertEqual(session.heldIdentifiers, [0], "rejected calls leave state untouched")
    }

    func testSixthFingerIsRejectedWithoutDisturbingTheFive() throws {
        let sender = RecordingHIDSender()
        let session = makeSession(sender)
        for id in 0..<5 { try session.down(identifier: UInt8(id), x: 0, y: 0) }
        XCTAssertThrowsError(try session.down(identifier: 0, x: 0, y: 0))
        XCTAssertEqual(session.heldIdentifiers, [0, 1, 2, 3, 4])
    }

    /// A failed send leaves the device's view unknown: everything that might
    /// be down, including the contact being put down, is lifted.
    func testFailedDownLiftsEverythingIncludingTheNewContact() throws {
        let sender = RecordingHIDSender()
        sender.failOnCall = 2
        let session = makeSession(sender)
        try session.down(identifier: 0, x: 1, y: 1)
        XCTAssertThrowsError(try session.down(identifier: 1, x: 2, y: 2)) { error in
            XCTAssertTrue(error is RecordingHIDSender.InjectedFailure)
        }
        let recovery = try XCTUnwrap(sender.sent.last)
        XCTAssertEqual(contacts(in: recovery.report), [
            TouchContact(identifier: 0, touching: false, x: 1, y: 1),
            TouchContact(identifier: 1, touching: false, x: 2, y: 2),
        ])
        XCTAssertEqual(session.heldIdentifiers, [])
    }

    func testFailedLiftDuringCloseStillForgetsAndClosesAndRethrows() throws {
        let sender = RecordingHIDSender()
        sender.failOnCall = 2
        let session = makeSession(sender)
        try session.down(identifier: 0, x: 1, y: 1)
        XCTAssertThrowsError(try session.close())
        XCTAssertEqual(sender.closeCount, 1)
        XCTAssertEqual(session.heldIdentifiers, [])
    }
}
