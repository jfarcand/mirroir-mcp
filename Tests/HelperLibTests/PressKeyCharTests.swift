// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the enhanced press_key command that supports single printable characters.
// ABOUTME: Validates that HIDKeyMap lookup works for characters used in keyboard shortcuts.

import Testing
@testable import HelperLib

@Suite("PressKeyChar")
struct PressKeyCharTests {

    // MARK: - Single Character Lookup

    @Test("Single character 'l' maps to HID keycode for Cmd+L shortcut")
    func lKeyLookup() {
        let mapping = HIDKeyMap.lookup(Character("l"))
        #expect(mapping != nil)
        #expect(mapping?.keycode == 0x0F)
        #expect(mapping?.modifiers == [])
    }

    @Test("Single character 'a' maps to HID keycode for Cmd+A shortcut")
    func aKeyLookup() {
        let mapping = HIDKeyMap.lookup(Character("a"))
        #expect(mapping != nil)
        #expect(mapping?.keycode == 0x04)
        #expect(mapping?.modifiers == [])
    }

    @Test("Single character 'c' maps to HID keycode for Cmd+C shortcut")
    func cKeyLookup() {
        let mapping = HIDKeyMap.lookup(Character("c"))
        #expect(mapping != nil)
        #expect(mapping?.keycode == 0x06)
        #expect(mapping?.modifiers == [])
    }

    @Test("Single character 'v' maps to HID keycode for Cmd+V shortcut")
    func vKeyLookup() {
        let mapping = HIDKeyMap.lookup(Character("v"))
        #expect(mapping != nil)
        #expect(mapping?.keycode == 0x19)
        #expect(mapping?.modifiers == [])
    }

    // MARK: - Modifier Merging for Uppercase Characters

    @Test("Uppercase 'L' includes leftShift in its own modifiers")
    func uppercaseLModifiers() {
        let mapping = HIDKeyMap.lookup(Character("L"))
        #expect(mapping != nil)
        #expect(mapping?.keycode == 0x0F)
        #expect(mapping?.modifiers == .leftShift)
    }

    @Test("Command modifier combined with uppercase character includes both")
    func commandPlusUppercaseModifiers() {
        // Simulates what handlePressKey does: merge command modifier with character's own modifiers
        var modifiers = HIDSpecialKeyMap.modifiers(from: ["command"])
        let mapping = HIDKeyMap.lookup(Character("L"))!
        modifiers.insert(mapping.modifiers)
        #expect(modifiers.contains(.leftCommand))
        #expect(modifiers.contains(.leftShift))
    }

    // MARK: - Digit Characters

    @Test("Digit characters map correctly for shortcuts like Cmd+1")
    func digitKeyLookup() {
        let mapping = HIDKeyMap.lookup(Character("1"))
        #expect(mapping != nil)
        #expect(mapping?.keycode == 0x1E)
        #expect(mapping?.modifiers == [])
    }
}
