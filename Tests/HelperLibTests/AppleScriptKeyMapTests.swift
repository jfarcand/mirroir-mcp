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

    // MARK: - Script Generation

    @Test("Script without modifiers has bare key code")
    func scriptWithoutModifiers() {
        let script = AppleScriptKeyMap.buildKeyPressScript(keyCode: 36)
        #expect(script.contains("key code 36"))
        #expect(!script.contains("using"))
    }

    @Test("Script activates iPhone Mirroring with set frontmost to true")
    func scriptActivatesApp() {
        let script = AppleScriptKeyMap.buildKeyPressScript(keyCode: 36)
        #expect(script.contains("tell process \"iPhone Mirroring\""))
        #expect(script.contains("set frontmost to true"))
    }

    @Test("Script includes delay for activation")
    func scriptIncludesDelay() {
        let script = AppleScriptKeyMap.buildKeyPressScript(keyCode: 36)
        #expect(script.contains("delay 0.1"))
    }

    @Test("Script restores previous frontmost app after keystroke")
    func scriptRestoresFocus() {
        let script = AppleScriptKeyMap.buildKeyPressScript(keyCode: 36)
        #expect(script.contains("set prevApp to name of first process whose frontmost is true"))
        #expect(script.contains("tell process prevApp"))
        // The restore delay must come after the key code line
        let keyCodeIndex = script.range(of: "key code 36")!.upperBound
        let restoreDelayRange = script.range(of: "delay 0.05")!.lowerBound
        #expect(restoreDelayRange > keyCodeIndex)
    }

    @Test("Single modifier produces using clause")
    func singleModifier() {
        let script = AppleScriptKeyMap.buildKeyPressScript(keyCode: 36, modifiers: ["command"])
        #expect(script.contains("key code 36 using {command down}"))
    }

    @Test("Multiple modifiers are comma-separated")
    func multipleModifiers() {
        let script = AppleScriptKeyMap.buildKeyPressScript(
            keyCode: 36, modifiers: ["command", "shift"]
        )
        #expect(script.contains("key code 36 using {command down, shift down}"))
    }

    @Test("All 4 modifiers are supported")
    func allModifiers() {
        let script = AppleScriptKeyMap.buildKeyPressScript(
            keyCode: 49, modifiers: ["command", "shift", "option", "control"]
        )
        #expect(script.contains("command down"))
        #expect(script.contains("shift down"))
        #expect(script.contains("option down"))
        #expect(script.contains("control down"))
    }

    @Test("Unknown modifiers are silently filtered out")
    func unknownModifiersFiltered() {
        let script = AppleScriptKeyMap.buildKeyPressScript(
            keyCode: 36, modifiers: ["command", "meta", "alt"]
        )
        // "meta" and "alt" are not in the modifier mapping, so only "command" survives
        #expect(script.contains("key code 36 using {command down}"))
        #expect(!script.contains("meta"))
        #expect(!script.contains("alt"))
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
