// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: DigitizerReport tests: go-ios's single-contact golden bytes, multi-contact layout, and validation.
// ABOUTME: Timestamp placement follows the UniversalHID descriptor (bytes 45..52), not go-ios (byte 44).
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation
import XCTest
@testable import MirroirCoreDevice

final class TouchscreenReportTests: XCTestCase {
    /// go-ios `goldenTimestamp`: 48 bits with distinct bytes.
    private let goldenTimestamp: UInt64 = 0x1234_5678_9ABC

    /// go-ios report_test.go golden bytes, adjusted only where the layouts
    /// disagree: go-ios writes the timestamp as 6 bytes at offset 44
    /// (`...02000000 bc9a78563412 0000000000000000`); the descriptor puts
    /// offset 44 in the identity field and an 8-byte timestamp at 45..52, so
    /// the same value lands one byte later (`...02000000 00 bc9a785634120000 0000000000`).
    private func golden(state: String) -> String {
        "090105" + state + "f401e803" + String(repeating: "00", count: 32)
            + "02000000" + "00" + "bc9a785634120000" + "0000000000"
    }

    func testSingleContactMatchesGoIOSGolden() throws {
        let report = try TouchscreenReport.build(
            contacts: [TouchContact(identifier: 2, touching: true, x: 500, y: 1000)], timestamp: goldenTimestamp)
        XCTAssertEqual(report.count, TouchscreenReport.length)
        XCTAssertEqual(Hex.encode(report), golden(state: "c2"))
    }

    func testSingleLiftMatchesGoIOSGolden() throws {
        let report = try TouchscreenReport.build(
            contacts: [TouchContact(identifier: 2, touching: false, x: 500, y: 1000)], timestamp: goldenTimestamp)
        XCTAssertEqual(Hex.encode(report), golden(state: "02"))
    }

    func testGoIOSPrefixIsUnchangedUpToTheTimestamp() throws {
        let goIOS = try Hex.decode("090105c2f401e803000000000000000000000000000000000000000000000000"
                                   + "000000000000000002000000bc9a785634120000000000000000")
        let report = try TouchscreenReport.build(
            contacts: [TouchContact(identifier: 2, touching: true, x: 500, y: 1000)], timestamp: goldenTimestamp)
        XCTAssertEqual(report.prefix(44), goIOS.prefix(44))
    }

    func testTwoContactsBothDown() throws {
        let report = [UInt8](try TouchscreenReport.build(contacts: [
            TouchContact(identifier: 0, touching: true, x: 0x1111, y: 0x2222),
            TouchContact(identifier: 1, touching: true, x: 0x3333, y: 0x4444),
        ], timestamp: 0))
        XCTAssertEqual(report[1], 2, "ContactCount")
        XCTAssertEqual(report[2], 5, "ContactCountMaximum")
        XCTAssertEqual(Array(report[3..<8]), [0xC0, 0x11, 0x11, 0x22, 0x22])
        XCTAssertEqual(Array(report[8..<13]), [0xC1, 0x33, 0x33, 0x44, 0x44])
        XCTAssertEqual(Array(report[13..<28]), [UInt8](repeating: 0, count: 15), "unused slots stay zero")
        XCTAssertEqual(Array(report[40..<45]), [2, 2, 0, 0, 0], "identity per described contact")
    }

    func testOneLiftedWhileTheOtherStaysDown() throws {
        let report = [UInt8](try TouchscreenReport.build(contacts: [
            TouchContact(identifier: 0, touching: false, x: 10, y: 20),
            TouchContact(identifier: 1, touching: true, x: 30, y: 40),
        ], timestamp: 0))
        XCTAssertEqual(report[1], 2, "the lifted contact is still described")
        XCTAssertEqual(report[3], 0x00, "contact 0: touch and inRange clear")
        XCTAssertEqual(report[8], 0xC1, "contact 1: still touching")
        XCTAssertEqual(Array(report[4..<8]), [10, 0, 20, 0], "lifted where it was")
    }

    func testFiveContactsFillEverySlotAndIdentity() throws {
        let contacts = (0..<5).map {
            TouchContact(identifier: UInt8($0), touching: true, x: UInt16.max, y: UInt16($0))
        }
        let report = [UInt8](try TouchscreenReport.build(contacts: contacts, timestamp: UInt64.max))
        XCTAssertEqual(report[1], 5)
        for slot in 0..<5 {
            let base = 3 + slot * 5
            XCTAssertEqual(Array(report[base..<(base + 5)]), [0xC0 | UInt8(slot), 0xFF, 0xFF, UInt8(slot), 0])
        }
        XCTAssertEqual(Array(report[40..<45]), [2, 2, 2, 2, 2])
        XCTAssertEqual(Array(report[45..<53]), [UInt8](repeating: 0xFF, count: 8), "full 64-bit timestamp")
        XCTAssertEqual(Array(report[53...]), [UInt8](repeating: 0, count: 5), "swipe flags untouched")
    }

    func testSixContactsAreRejected() {
        let contacts = (0..<6).map { TouchContact(identifier: UInt8($0 % 5), touching: true, x: 0, y: 0) }
        XCTAssertThrowsError(try TouchscreenReport.build(contacts: contacts, timestamp: 0)) { error in
            XCTAssertEqual(error as? TouchReportError, .contactCountOutOfRange(count: 6, maximum: 5))
        }
    }

    func testEmptyReportIsRejected() {
        XCTAssertThrowsError(try TouchscreenReport.build(contacts: [], timestamp: 0)) { error in
            XCTAssertEqual(error as? TouchReportError, .contactCountOutOfRange(count: 0, maximum: 5))
        }
    }

    func testIdentifierOutsideDescriptorRangeIsRejected() {
        XCTAssertThrowsError(try TouchscreenReport.build(
            contacts: [TouchContact(identifier: 5, touching: true, x: 0, y: 0)], timestamp: 0)) { error in
            XCTAssertEqual(error as? TouchReportError, .contactIdentifierOutOfRange(identifier: 5, maximum: 4))
        }
    }

    func testDuplicateIdentifiersAreRejected() {
        XCTAssertThrowsError(try TouchscreenReport.build(contacts: [
            TouchContact(identifier: 1, touching: true, x: 0, y: 0),
            TouchContact(identifier: 1, touching: false, x: 0, y: 0),
        ], timestamp: 0)) { error in
            XCTAssertEqual(error as? TouchReportError, .duplicateContactIdentifier(1))
        }
    }

    func testCoordinateExtremesEncodeLittleEndian() throws {
        let report = [UInt8](try TouchscreenReport.build(
            contacts: [TouchContact(identifier: 4, touching: true, x: 0, y: 0xFFFF)], timestamp: 0))
        XCTAssertEqual(Array(report[3..<8]), [0xC4, 0x00, 0x00, 0xFF, 0xFF])
    }
}
