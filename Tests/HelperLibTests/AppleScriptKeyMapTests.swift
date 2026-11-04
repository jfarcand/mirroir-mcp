// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AppleScript key mapping, script generation, and text escaping.
// ABOUTME: Validates key codes, modifier handling, and safe string escaping for AppleScript.

import Testing
@testable import HelperLib

@Suite("AppleScriptKeyMap")
struct AppleScriptKeyMapTests {

    // MARK: - Key Code Lookup

    @Test("All 9 key names map to correct macOS virtual key codes")
    func keyCodeLookup() {
        let expected: [(String, UInt16)] = [
            ("return", 36),
            ("escape", 53),
            ("tab", 48),
            ("delete", 51),
            ("space", 49),
            ("up", 126),
            ("down", 125),
            ("left", 123),
            ("right", 124),
        ]
        for (name, code) in expected {
            let result = AppleScriptKeyMap.keyCode(for: name)
            #expect(result == code, "Key '\(name)' should map to \(code), got \(String(describing: result))")
        }
    }

    @Test("Unknown key names return nil")
    func unknownKeyNames() {
        #expect(AppleScriptKeyMap.keyCode(for: "enter") == nil)
        #expect(AppleScriptKeyMap.keyCode(for: "backspace") == nil)
        #expect(AppleScriptKeyMap.keyCode(for: "f1") == nil)
        #expect(AppleScriptKeyMap.keyCode(for: "") == nil)
    }

    @Test("Key names are case-sensitive (uppercase returns nil)")
    func caseSensitivity() {
        #expect(AppleScriptKeyMap.keyCode(for: "Return") == nil)
        #expect(AppleScriptKeyMap.keyCode(for: "ESCAPE") == nil)
        #expect(AppleScriptKeyMap.keyCode(for: "Tab") == nil)
    }

    // MARK: - AppleScript Escaping

    @Test("Backslashes are doubled")
    func escapeBackslashes() {
        let result = AppleScriptKeyMap.escapeForAppleScript("path\\to\\file")
        #expect(result == "path\\\\to\\\\file")
    }

    @Test("Double quotes are backslash-escaped")
    func escapeDoubleQuotes() {
        let result = AppleScriptKeyMap.escapeForAppleScript("say \"hello\"")
        #expect(result == "say \\\"hello\\\"")
    }

    @Test("Text with both backslashes and quotes is escaped correctly")
    func escapeBoth() {
        let result = AppleScriptKeyMap.escapeForAppleScript("a\\\"b")
        #expect(result == "a\\\\\\\"b")
    }

    @Test("Plain text passes through unchanged")
    func escapePlainText() {
        let result = AppleScriptKeyMap.escapeForAppleScript("hello world 123")
        #expect(result == "hello world 123")
    }

    @Test("Empty string passes through unchanged")
    func escapeEmptyString() {
        let result = AppleScriptKeyMap.escapeForAppleScript("")
        #expect(result == "")
    }

    // MARK: - supportedKeys

    @Test("supportedKeys returns all 9 keys sorted alphabetically")
    func supportedKeysCount() {
        let keys = AppleScriptKeyMap.supportedKeys
        #expect(keys.count == 9)
        #expect(keys == keys.sorted())
        #expect(keys.contains("return"))
        #expect(keys.contains("escape"))
        #expect(keys.contains("up"))
    }
}
