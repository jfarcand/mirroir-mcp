// ABOUTME: Tests for HID special key mapping used by the Karabiner virtual keyboard.
// ABOUTME: Validates USB HID keycodes, modifier conversion, and parity with AppleScriptKeyMap.

import Testing
@testable import HelperLib

@Suite("HIDSpecialKeyMap")
struct HIDSpecialKeyMapTests {

    // MARK: - Key Code Lookup

    @Test("All 9 key names map to correct USB HID keycodes")
    func hidKeyCodeLookup() {
        let expected: [(String, UInt16)] = [
            ("return", 0x28),
            ("escape", 0x29),
            ("delete", 0x2A),
            ("tab", 0x2B),
            ("space", 0x2C),
            ("right", 0x4F),
            ("left", 0x50),
            ("down", 0x51),
            ("up", 0x52),
        ]
        for (name, code) in expected {
            let result = HIDSpecialKeyMap.hidKeyCode(for: name)
            #expect(result == code, "Key '\(name)' should map to 0x\(String(code, radix: 16)), got \(result.map { "0x\(String($0, radix: 16))" } ?? "nil")")
        }
    }

    @Test("Unknown key names return nil")
    func unknownKeyNames() {
        #expect(HIDSpecialKeyMap.hidKeyCode(for: "enter") == nil)
        #expect(HIDSpecialKeyMap.hidKeyCode(for: "backspace") == nil)
        #expect(HIDSpecialKeyMap.hidKeyCode(for: "f1") == nil)
        #expect(HIDSpecialKeyMap.hidKeyCode(for: "") == nil)
    }

    @Test("Key names are case-sensitive (uppercase returns nil)")
    func caseSensitivity() {
        #expect(HIDSpecialKeyMap.hidKeyCode(for: "Return") == nil)
        #expect(HIDSpecialKeyMap.hidKeyCode(for: "ESCAPE") == nil)
        #expect(HIDSpecialKeyMap.hidKeyCode(for: "Tab") == nil)
    }

    // MARK: - supportedKeys

    @Test("supportedKeys returns all 9 keys sorted alphabetically")
    func supportedKeysCount() {
        let keys = HIDSpecialKeyMap.supportedKeys
        #expect(keys.count == 9)
        #expect(keys == keys.sorted())
        #expect(keys.contains("return"))
        #expect(keys.contains("escape"))
        #expect(keys.contains("up"))
    }

    // MARK: - Modifier Mapping

    @Test("Single modifier names map to correct KeyboardModifier values")
    func singleModifiers() {
        #expect(HIDSpecialKeyMap.modifiers(from: ["command"]) == .leftCommand)
        #expect(HIDSpecialKeyMap.modifiers(from: ["shift"]) == .leftShift)
        #expect(HIDSpecialKeyMap.modifiers(from: ["option"]) == .leftOption)
        #expect(HIDSpecialKeyMap.modifiers(from: ["control"]) == .leftControl)
    }

    @Test("Multiple modifiers combine into a bitmask")
    func combinedModifiers() {
        let mods = HIDSpecialKeyMap.modifiers(from: ["command", "shift"])
        #expect(mods.contains(.leftCommand))
        #expect(mods.contains(.leftShift))
        #expect(!mods.contains(.leftOption))
    }

    @Test("Unknown modifier names are silently ignored")
    func unknownModifiers() {
        let mods = HIDSpecialKeyMap.modifiers(from: ["command", "meta", "alt"])
        #expect(mods == .leftCommand)
    }

    @Test("Empty modifier list produces empty bitmask")
    func emptyModifiers() {
        let mods = HIDSpecialKeyMap.modifiers(from: [])
        #expect(mods == KeyboardModifier())
    }

    @Test("supportedModifiers returns all 4 modifier names")
    func supportedModifiersCount() {
        let mods = HIDSpecialKeyMap.supportedModifiers
        #expect(mods.count == 4)
        #expect(mods == mods.sorted())
        #expect(mods.contains("command"))
        #expect(mods.contains("shift"))
        #expect(mods.contains("option"))
        #expect(mods.contains("control"))
    }

    // MARK: - Parity with AppleScriptKeyMap

    @Test("HIDSpecialKeyMap.supportedKeys matches AppleScriptKeyMap.supportedKeys")
    func supportedKeysParity() {
        let hidKeys = Set(HIDSpecialKeyMap.supportedKeys)
        let asKeys = Set(AppleScriptKeyMap.supportedKeys)
        #expect(hidKeys == asKeys, "HID keys \(hidKeys) should equal AppleScript keys \(asKeys)")
    }
}
