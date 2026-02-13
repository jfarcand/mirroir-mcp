// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the shake gesture implementation constants.
// ABOUTME: Validates that HID keycode 0x1D maps to 'z' and modifier bitmasks are correct.

import Testing
@testable import HelperLib

@Suite("ShakeGesture")
struct ShakeGestureTests {

    // MARK: - Keycode Validation

    @Test("HID keycode 0x1D maps to lowercase 'z'")
    func zKeycode() {
        let mapping = HIDKeyMap.lookup(Character("z"))
        #expect(mapping != nil)
        #expect(mapping?.keycode == 0x1D)
        #expect(mapping?.modifiers == [])
    }

    @Test("HID keycode 0x1D maps to uppercase 'Z' with leftShift")
    func capitalZKeycode() {
        let mapping = HIDKeyMap.lookup(Character("Z"))
        #expect(mapping != nil)
        #expect(mapping?.keycode == 0x1D)
        #expect(mapping?.modifiers == .leftShift)
    }

    // MARK: - Modifier Validation

    @Test("Control + Command modifiers combine to 0x09")
    func controlCommandModifiers() {
        let mods: KeyboardModifier = [.leftControl, .leftCommand]
        // leftControl = 0x01, leftCommand = 0x08
        #expect(mods.rawValue == 0x09)
    }

    @Test("Shake modifier bitmask includes both control and command")
    func shakeModifierBitmask() {
        let mods: KeyboardModifier = [.leftControl, .leftCommand]
        #expect(mods.contains(.leftControl))
        #expect(mods.contains(.leftCommand))
        #expect(!mods.contains(.leftShift))
        #expect(!mods.contains(.leftOption))
    }

    @Test("HIDSpecialKeyMap modifier lookup matches shake requirements")
    func specialKeyMapModifierLookup() {
        let mods = HIDSpecialKeyMap.modifiers(from: ["control", "command"])
        #expect(mods == [.leftControl, .leftCommand])
        #expect(mods.rawValue == 0x09)
    }
}
