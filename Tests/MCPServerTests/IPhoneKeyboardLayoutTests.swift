// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for IPhoneKeyboardLayout: the keystrokes that type URL characters on US QWERTY and Canadian-CSA.
// ABOUTME: Pins carnet#3 — "/" on a Canadian-CSA iPhone is the ISO section key, never US QWERTY's "/" key ("é").

import CoreGraphics
import XCTest
@testable import mirroir_mcp

final class IPhoneKeyboardLayoutTests: XCTestCase {

    /// macOS virtual keycodes the URL characters live on.
    private enum Key {
        static let isoSection: UInt16 = 0x0A
        static let six: UInt16 = 0x16
        static let seven: UInt16 = 0x1A
        static let equal: UInt16 = 0x18
        static let minus: UInt16 = 0x1B
        static let semicolon: UInt16 = 0x29
        static let slash: UInt16 = 0x2C
        static let period: UInt16 = 0x2F
    }

    private func stroke(_ keycode: UInt16, shift: Bool = false) -> CGKeySequence {
        CGKeySequence(steps: [CGKeyMapping(
            keycode: keycode, flags: shift ? .maskShift : CGEventFlags())])
    }

    private func csa() throws -> IPhoneKeyboardLayout {
        try XCTUnwrap(IPhoneKeyboardLayout.named("Canadian-CSA"),
                      "Canadian-CSA layout not available on this system")
    }

    // MARK: - Layout names

    func testEmptyAndUSNamesAreUSQWERTY() throws {
        XCTAssertNil(try XCTUnwrap(IPhoneKeyboardLayout.named("")).sourceID)
        XCTAssertNil(try XCTUnwrap(IPhoneKeyboardLayout.named("US")).sourceID)
        XCTAssertNil(try XCTUnwrap(
            IPhoneKeyboardLayout.named("com.apple.keylayout.US")).sourceID)
    }

    func testShortAndFullCSANamesResolveToTheSameLayout() throws {
        let full = try XCTUnwrap(
            IPhoneKeyboardLayout.named("com.apple.keylayout.Canadian-CSA"))
        XCTAssertEqual(try csa().sourceID, "com.apple.keylayout.Canadian-CSA")
        XCTAssertEqual(full.sourceID, "com.apple.keylayout.Canadian-CSA")
    }

    func testUnknownLayoutNameIsNotSilentlyUS() {
        XCTAssertNil(IPhoneKeyboardLayout.named("Nonexistent-Layout-XYZ"))
    }

    // MARK: - US QWERTY URL characters

    func testUSURLCharacters() {
        let us = IPhoneKeyboardLayout.usQWERTY
        XCTAssertEqual(us.keySequence(for: "/"), stroke(Key.slash))
        XCTAssertEqual(us.keySequence(for: ":"), stroke(Key.semicolon, shift: true))
        XCTAssertEqual(us.keySequence(for: "."), stroke(Key.period))
        XCTAssertEqual(us.keySequence(for: "?"), stroke(Key.slash, shift: true))
        XCTAssertEqual(us.keySequence(for: "="), stroke(Key.equal))
        XCTAssertEqual(us.keySequence(for: "&"), stroke(Key.seven, shift: true))
        XCTAssertEqual(us.keySequence(for: "-"), stroke(Key.minus))
        XCTAssertEqual(us.keySequence(for: "_"), stroke(Key.minus, shift: true))
    }

    // MARK: - Canadian-CSA URL characters

    func testCSASlashIsTheISOSectionKey() throws {
        // US QWERTY's "/" key types "é" on Canadian-CSA — the garbled-URL bug.
        XCTAssertEqual(try csa().keySequence(for: "/"), stroke(Key.isoSection))
        XCTAssertEqual(try csa().keySequence(for: "é"), stroke(Key.slash))
    }

    func testCSAURLCharacters() throws {
        let csa = try csa()
        XCTAssertEqual(csa.keySequence(for: ":"), stroke(Key.semicolon, shift: true))
        XCTAssertEqual(csa.keySequence(for: "."), stroke(Key.period))
        XCTAssertEqual(csa.keySequence(for: "?"), stroke(Key.six, shift: true))
        XCTAssertEqual(csa.keySequence(for: "="), stroke(Key.equal))
        XCTAssertEqual(csa.keySequence(for: "&"), stroke(Key.seven, shift: true))
        XCTAssertEqual(csa.keySequence(for: "-"), stroke(Key.minus))
        XCTAssertEqual(csa.keySequence(for: "_"), stroke(Key.minus, shift: true))
    }

    func testCSAEveryURLCharacterHasASingleKeystroke() throws {
        let csa = try csa()
        for char in "http://10.0.0.237:18902/parity.html?a=1&b_c-d" {
            let sequence = csa.keySequence(for: char)
            XCTAssertEqual(sequence?.steps.count, 1, "'\(char)' should be one keystroke")
        }
    }

    func testCSADeadKeyCharacterIsCircumflexThenBase() throws {
        // "^" (keycode 0x21) is a dead key on Canadian-CSA: it composes with the next key.
        let expected = CGKeySequence(steps: [
            CGKeyMapping(keycode: 0x21, flags: CGEventFlags()),
            CGKeyMapping(keycode: 0x0E, flags: CGEventFlags()),
        ])
        XCTAssertEqual(try csa().keySequence(for: "ê"), expected)
    }

    func testCSAFrenchTextNeedsNoClipboard() throws {
        // Every character here has keys on Canadian-CSA, so typing it must
        // never fall back to the clipboard (which needs Universal Clipboard).
        let csa = try csa()
        for char in "fête à l'hôtel: ça déçoit Noël, où êtes-vous?" {
            XCTAssertNotNil(csa.keySequence(for: char), "'\(char)' should have keys on Canadian-CSA")
        }
    }
}
