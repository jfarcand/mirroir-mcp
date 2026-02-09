// ABOUTME: Tests for keyboard layout translation using UCKeyTranslate.
// ABOUTME: Validates substitution table construction, character translation, and US QWERTY keycode mapping.

import Testing
@testable import HelperLib

// TIS (Text Input Source) APIs are not thread-safe — concurrent calls crash.
// Swift-testing runs tests in parallel, so this suite must be serialized.
@Suite("LayoutMapper", .serialized)
struct LayoutMapperTests {

    // MARK: - Translate

    @Test("translate passes through text when substitution is empty")
    func translateEmptySubstitution() {
        let text = "Hello, World! /path/to/file"
        let result = LayoutMapper.translate(text, substitution: [:])
        #expect(result == text)
    }

    @Test("translate applies character substitution")
    func translateAppliesSubstitution() {
        let substitution: [Character: Character] = [
            "/": "?",
            ".": ">",
        ]
        let result = LayoutMapper.translate("a/b.c", substitution: substitution)
        #expect(result == "a?b>c")
    }

    @Test("translate preserves characters not in substitution table")
    func translatePreservesUnmappedChars() {
        let substitution: [Character: Character] = ["x": "y"]
        let result = LayoutMapper.translate("hello x world", substitution: substitution)
        #expect(result == "hello y world")
    }

    // MARK: - US QWERTY Layout Data

    @Test("US QWERTY layout data is accessible")
    func usLayoutDataExists() {
        let data = LayoutMapper.layoutData(forSourceID: "com.apple.keylayout.US")
        #expect(data != nil, "US QWERTY layout data should always be available on macOS")
    }

    // MARK: - UCKeyTranslate with US QWERTY

    @Test("translateKeycode produces correct US QWERTY letters")
    func usQwertyLetters() {
        guard let usData = LayoutMapper.layoutData(forSourceID: "com.apple.keylayout.US") else {
            Issue.record("US QWERTY layout data not found")
            return
        }

        // Virtual keycode 0x00 = 'a' on US QWERTY (no modifier)
        let a = LayoutMapper.translateKeycode(0x00, modifiers: 0, layoutData: usData)
        #expect(a == "a")

        // Virtual keycode 0x00 = 'A' on US QWERTY (shift)
        let shiftA = LayoutMapper.translateKeycode(0x00, modifiers: 2, layoutData: usData)
        #expect(shiftA == "A")
    }

    @Test("translateKeycode produces correct US QWERTY digits")
    func usQwertyDigits() {
        guard let usData = LayoutMapper.layoutData(forSourceID: "com.apple.keylayout.US") else {
            Issue.record("US QWERTY layout data not found")
            return
        }

        // Virtual keycode 0x12 = '1' key on US QWERTY
        let one = LayoutMapper.translateKeycode(0x12, modifiers: 0, layoutData: usData)
        #expect(one == "1")

        // Virtual keycode 0x12 + shift = '!' on US QWERTY
        let excl = LayoutMapper.translateKeycode(0x12, modifiers: 2, layoutData: usData)
        #expect(excl == "!")
    }

    @Test("translateKeycode produces correct US QWERTY punctuation")
    func usQwertyPunctuation() {
        guard let usData = LayoutMapper.layoutData(forSourceID: "com.apple.keylayout.US") else {
            Issue.record("US QWERTY layout data not found")
            return
        }

        // Virtual keycode 0x2C = '/' on US QWERTY
        let slash = LayoutMapper.translateKeycode(0x2C, modifiers: 0, layoutData: usData)
        #expect(slash == "/")

        // Virtual keycode 0x2F = '.' on US QWERTY
        let dot = LayoutMapper.translateKeycode(0x2F, modifiers: 0, layoutData: usData)
        #expect(dot == ".")
    }

    // MARK: - Substitution Table Construction

    @Test("same layout produces empty substitution table")
    func sameLayoutEmptySubstitution() {
        guard let usData = LayoutMapper.layoutData(forSourceID: "com.apple.keylayout.US") else {
            Issue.record("US QWERTY layout data not found")
            return
        }

        let substitution = LayoutMapper.buildSubstitution(
            usLayoutData: usData, targetLayoutData: usData
        )
        #expect(substitution.isEmpty, "Same layout should produce no substitutions")
    }

    @Test("Canadian-CSA layout produces substitutions for accented characters")
    func canadianCSASubstitution() {
        guard let usData = LayoutMapper.layoutData(forSourceID: "com.apple.keylayout.US") else {
            Issue.record("US QWERTY layout data not found")
            return
        }

        guard let csaData = LayoutMapper.layoutData(
            forSourceID: "com.apple.keylayout.Canadian-CSA"
        ) else {
            Issue.record("Canadian-CSA layout data not found")
            return
        }

        let substitution = LayoutMapper.buildSubstitution(
            usLayoutData: usData, targetLayoutData: csaData
        )
        #expect(!substitution.isEmpty,
                "Canadian-CSA should differ from US QWERTY")

        // The / key on US QWERTY (vk 0x2C) produces é on Canadian-CSA.
        // To type é on iPhone, send / to the helper.
        #expect(substitution[Character("é")] == Character("/"),
                "é should map to / for Canadian-CSA")
    }

    // MARK: - Round-Trip Consistency

    @Test("Canadian-CSA substitutions are mostly HID-typeable with paste fallback for ISO keys")
    func substitutionHIDCoverage() {
        guard let usData = LayoutMapper.layoutData(forSourceID: "com.apple.keylayout.US"),
              let csaData = LayoutMapper.layoutData(
                  forSourceID: "com.apple.keylayout.Canadian-CSA")
        else {
            return
        }

        let substitution = LayoutMapper.buildSubstitution(
            usLayoutData: usData, targetLayoutData: csaData
        )

        // Most substitutions should have HID mappings. Characters that map to
        // the ISO section key (§, ±) have no HID entry because Mac and iPhone
        // CSA layouts interpret that key differently. Those characters are
        // typed via clipboard paste instead.
        var hidCount = 0
        for (_, usChar) in substitution {
            if HIDKeyMap.lookup(usChar) != nil {
                hidCount += 1
            }
        }
        #expect(hidCount > 0, "At least some substitutions should be HID-typeable")
        #expect(hidCount >= substitution.count - 2,
                "At most 2 substitutions (§, ±) should need paste fallback")
    }
}
