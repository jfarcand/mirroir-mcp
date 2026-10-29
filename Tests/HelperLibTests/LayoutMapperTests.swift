// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for keyboard layout reading using UCKeyTranslate.
// ABOUTME: Validates keycode translation, dead-key detection, and the per-layout key table for US and Canadian-CSA.

import Darwin
import Foundation
import Testing
@testable import HelperLib

// TIS (Text Input Source) APIs are not thread-safe — concurrent calls crash.
// Swift-testing runs tests in parallel, so this suite must be serialized.
@Suite("LayoutMapper", .serialized)
struct LayoutMapperTests {

    /// Characters a URL needs, with the US QWERTY key that types each.
    private static let usURLKeys: [(Character, LayoutKeyStroke)] = [
        ("/", LayoutKeyStroke(keycode: 0x2C, shift: false)),
        (":", LayoutKeyStroke(keycode: 0x29, shift: true)),
        (".", LayoutKeyStroke(keycode: 0x2F, shift: false)),
        ("?", LayoutKeyStroke(keycode: 0x2C, shift: true)),
        ("=", LayoutKeyStroke(keycode: 0x18, shift: false)),
        ("&", LayoutKeyStroke(keycode: 0x1A, shift: true)),
        ("-", LayoutKeyStroke(keycode: 0x1B, shift: false)),
        ("_", LayoutKeyStroke(keycode: 0x1B, shift: true)),
    ]

    /// The same characters on Canadian-CSA. "/" is the ISO section key and
    /// "?" is Shift+6; US QWERTY's "/" key types "é".
    private static let csaURLKeys: [(Character, LayoutKeyStroke)] = [
        ("/", LayoutKeyStroke(keycode: 0x0A, shift: false)),
        (":", LayoutKeyStroke(keycode: 0x29, shift: true)),
        (".", LayoutKeyStroke(keycode: 0x2F, shift: false)),
        ("?", LayoutKeyStroke(keycode: 0x16, shift: true)),
        ("=", LayoutKeyStroke(keycode: 0x18, shift: false)),
        ("&", LayoutKeyStroke(keycode: 0x1A, shift: true)),
        ("-", LayoutKeyStroke(keycode: 0x1B, shift: false)),
        ("_", LayoutKeyStroke(keycode: 0x1B, shift: true)),
    ]

    private func layout(_ sourceID: String) -> Data? {
        let data = LayoutMapper.layoutData(forSourceID: sourceID)
        if data == nil { Issue.record("\(sourceID) layout data not found") }
        return data
    }

    // MARK: - Layout Data

    @Test("US QWERTY layout data is accessible")
    func usLayoutDataExists() {
        let data = LayoutMapper.layoutData(forSourceID: "com.apple.keylayout.US")
        #expect(data != nil, "US QWERTY layout data should always be available on macOS")
    }

    // MARK: - UCKeyTranslate with US QWERTY

    @Test("translateKeycode produces correct US QWERTY letters")
    func usQwertyLetters() throws {
        let usData = try #require(layout(LayoutMapper.usSourceID))

        // Virtual keycode 0x00 = 'a' on US QWERTY (no modifier)
        let a = LayoutMapper.translateKeycode(0x00, modifiers: 0, layoutData: usData)
        #expect(a == "a")

        // Virtual keycode 0x00 = 'A' on US QWERTY (shift)
        let shiftA = LayoutMapper.translateKeycode(0x00, modifiers: 2, layoutData: usData)
        #expect(shiftA == "A")
    }

    @Test("translateKeycode produces correct US QWERTY digits")
    func usQwertyDigits() throws {
        let usData = try #require(layout(LayoutMapper.usSourceID))

        // Virtual keycode 0x12 = '1' key on US QWERTY
        let one = LayoutMapper.translateKeycode(0x12, modifiers: 0, layoutData: usData)
        #expect(one == "1")

        // Virtual keycode 0x12 + shift = '!' on US QWERTY
        let excl = LayoutMapper.translateKeycode(0x12, modifiers: 2, layoutData: usData)
        #expect(excl == "!")
    }

    @Test("translateKeycode produces correct US QWERTY punctuation")
    func usQwertyPunctuation() throws {
        let usData = try #require(layout(LayoutMapper.usSourceID))

        // Virtual keycode 0x2C = '/' on US QWERTY
        let slash = LayoutMapper.translateKeycode(0x2C, modifiers: 0, layoutData: usData)
        #expect(slash == "/")

        // Virtual keycode 0x2F = '.' on US QWERTY
        let dot = LayoutMapper.translateKeycode(0x2F, modifiers: 0, layoutData: usData)
        #expect(dot == ".")
    }

    // MARK: - Dead Keys

    @Test("isDeadKey flags Canadian-CSA's circumflex key and not its letters")
    func csaDeadKey() throws {
        let csaData = try #require(layout("com.apple.keylayout.Canadian-CSA"))
        // 0x21 is "^" on Canadian-CSA, a dead key that composes with the next key.
        #expect(LayoutMapper.isDeadKey(0x21, modifiers: 0, layoutData: csaData))
        #expect(!LayoutMapper.isDeadKey(0x00, modifiers: 0, layoutData: csaData))
    }

    // MARK: - Key Table

    @Test("US QWERTY key table types every URL character with its US key")
    func usKeyTableURLCharacters() throws {
        let usData = try #require(layout(LayoutMapper.usSourceID))
        let table = LayoutMapper.keyTable(layoutData: usData)
        for (char, stroke) in Self.usURLKeys {
            #expect(table[char] == stroke, "US '\(char)'")
        }
    }

    @Test("Canadian-CSA key table types every URL character with its CSA key")
    func csaKeyTableURLCharacters() throws {
        let csaData = try #require(layout("com.apple.keylayout.Canadian-CSA"))
        let table = LayoutMapper.keyTable(layoutData: csaData)
        for (char, stroke) in Self.csaURLKeys {
            #expect(table[char] == stroke, "Canadian-CSA '\(char)'")
        }
    }

    @Test("Canadian-CSA types é on US QWERTY's slash key")
    func csaKeyTableAccent() throws {
        let csaData = try #require(layout("com.apple.keylayout.Canadian-CSA"))
        let table = LayoutMapper.keyTable(layoutData: csaData)
        #expect(table["é"] == LayoutKeyStroke(keycode: 0x2C, shift: false))
        #expect(table["É"] == LayoutKeyStroke(keycode: 0x2C, shift: true))
    }

    @Test("Key table leaves out dead keys and the compositions they start")
    func keyTableOmitsDeadKeys() throws {
        let csaData = try #require(layout("com.apple.keylayout.Canadian-CSA"))
        let table = LayoutMapper.keyTable(layoutData: csaData)
        #expect(table["^"] != LayoutKeyStroke(keycode: 0x21, shift: false),
                "a dead key must not be recorded as typing its accent")
        #expect(table["ê"] == nil, "ê needs two keystrokes on Canadian-CSA")
    }

    @Test("Canadian-CSA composes circumflex and diaeresis letters from its dead keys")
    func csaDeadKeyCompositions() throws {
        let csaData = try #require(layout("com.apple.keylayout.Canadian-CSA"))
        let compositions = LayoutMapper.deadKeyCompositions(layoutData: csaData)
        let circumflex = LayoutKeyStroke(keycode: 0x21, shift: false)
        #expect(compositions["ê"] == [circumflex, LayoutKeyStroke(keycode: 0x0E, shift: false)])
        #expect(compositions["ô"] == [circumflex, LayoutKeyStroke(keycode: 0x1F, shift: false)])
        #expect(compositions["Ê"] == [circumflex, LayoutKeyStroke(keycode: 0x0E, shift: true)])
        let diaeresis = LayoutKeyStroke(keycode: 0x21, shift: true)
        #expect(compositions["ë"] == [diaeresis, LayoutKeyStroke(keycode: 0x0E, shift: false)])
    }

    @Test("Every dead-key composition is two keystrokes that emit exactly its character")
    func compositionsEmitOneCharacter() throws {
        let csaData = try #require(layout("com.apple.keylayout.Canadian-CSA"))
        let compositions = LayoutMapper.deadKeyCompositions(layoutData: csaData)
        #expect(!compositions.isEmpty)
        for (char, strokes) in compositions {
            #expect(strokes.count == 2, "'\(char)'")
            #expect(LayoutMapper.composedCharacter(dead: strokes[0], base: strokes[1],
                                                   layoutData: csaData) == char, "'\(char)'")
        }
        let circumflex = LayoutKeyStroke(keycode: 0x21, shift: false)
        #expect(LayoutMapper.composedCharacter(dead: circumflex, base: LayoutKeyStroke(keycode: 0x07, shift: false),
                                               layoutData: csaData) == nil,
                "^ then x does not combine and must not count as a composition")
    }

    @Test("Key table prefers the unshifted key for a character reachable both ways")
    func keyTablePrefersUnshifted() throws {
        let usData = try #require(layout(LayoutMapper.usSourceID))
        let table = LayoutMapper.keyTable(layoutData: usData)
        #expect(table["a"] == LayoutKeyStroke(keycode: 0x00, shift: false))
        #expect(table["A"] == LayoutKeyStroke(keycode: 0x00, shift: true))
    }

    // MARK: - Layout names

    @Test("sourceID expands short layout names")
    func sourceIDExpansion() {
        #expect(LayoutMapper.sourceID(forLayout: "Canadian-CSA")
                == "com.apple.keylayout.Canadian-CSA")
        #expect(LayoutMapper.sourceID(forLayout: "com.apple.keylayout.Canadian-CSA")
                == "com.apple.keylayout.Canadian-CSA")
    }

    @Test("isUSLayout accepts empty, short and full US names only")
    func usLayoutNames() {
        #expect(LayoutMapper.isUSLayout(""))
        #expect(LayoutMapper.isUSLayout("US"))
        #expect(LayoutMapper.isUSLayout("com.apple.keylayout.US"))
        #expect(!LayoutMapper.isUSLayout("Canadian-CSA"))
    }

    // MARK: - findNonUSLayout

    @Test("findNonUSLayout returns nil when layout is empty")
    func findNonUSLayoutDefaultReturnsNil() {
        let result = LayoutMapper.findNonUSLayout(layout: "")
        #expect(result == nil, "Empty layout should return nil (US QWERTY default)")
    }

    @Test("findNonUSLayout returns nil for US")
    func findNonUSLayoutUSReturnsNil() {
        #expect(LayoutMapper.findNonUSLayout(layout: "US") == nil)
    }

    @Test("findNonUSLayout returns layout for Canadian-CSA")
    func findNonUSLayoutWithCanadianCSA() {
        let result = LayoutMapper.findNonUSLayout(layout: "Canadian-CSA")
        #expect(result != nil, "Canadian-CSA should return layout data")
        #expect(result?.sourceID == "com.apple.keylayout.Canadian-CSA")
    }

    @Test("findNonUSLayout accepts full source ID")
    func findNonUSLayoutWithFullSourceID() {
        let result = LayoutMapper.findNonUSLayout(layout: "com.apple.keylayout.Canadian-CSA")
        #expect(result != nil, "Full source ID should be accepted")
        #expect(result?.sourceID == "com.apple.keylayout.Canadian-CSA")
    }

    @Test("findNonUSLayout returns nil for unknown layout name")
    func findNonUSLayoutWithUnknownLayout() {
        let result = LayoutMapper.findNonUSLayout(layout: "Nonexistent-Layout-XYZ")
        #expect(result == nil, "Unknown layout should return nil")
    }
}
