/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Tests for the SkyLight records that give a window keyboard focus: activation first, then key window.
// ABOUTME: Checks the bytes of each record against the window server's layout (type 0x08, number 0x8a, window 0x3c).

import XCTest
@testable import mirroir_mcp

final class SkyLightFocusRecordTests: XCTestCase {

    private let windowID: CGWindowID = 134_183

    private var records: [[UInt8]] {
        SkyLightWindowPoster.focusKeyFills.map { SkyLightWindowPoster.record(windowID: windowID, fill: $0) }
    }

    private func int16(_ record: [UInt8], at offset: Int) -> Int16 {
        Int16(record[offset]) | Int16(record[offset + 1]) << 8
    }

    private func uint32(_ record: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(record[offset + $1]) << (8 * $1) }
    }

    /// carnet#80: keys never reached an iOS 27 phone until the app was told
    /// it is active; the activation goes before the key-window pair.
    func testTheAppIsActivatedBeforeItsWindowIsMadeKey() {
        let types = records.map { $0[0x08] }
        XCTAssertEqual(types, [0x0d, 0x01, 0x02], "activation, then a mouse-down/up pair")
    }

    func testTheActivationRecordIsTheApplicationActivatedEvent() throws {
        let activation = try XCTUnwrap(records.first)
        XCTAssertEqual(activation[0x08], 0x0d, "an AppKit-defined event")
        XCTAssertEqual(int16(activation, at: 0x8a), 0x01, "subtype: application activated")
        XCTAssertEqual(Array(activation[0x20..<0x30]), Array(repeating: 0, count: 16),
                       "no location: it is not a click")
    }

    func testTheKeyWindowPairHasABlankedLocation() {
        for record in records.dropFirst() {
            XCTAssertEqual(Array(record[0x20..<0x30]), Array(repeating: 0xff, count: 16))
        }
    }

    func testEveryRecordNamesTheWindow() {
        for record in records {
            XCTAssertEqual(record.count, 0xf8)
            XCTAssertEqual(record[0x04], 0xf8, "record length")
            XCTAssertEqual(record[0x3a], 0x10, "addressed to a window")
            XCTAssertEqual(uint32(record, at: 0x3c), UInt32(windowID))
        }
    }
}
