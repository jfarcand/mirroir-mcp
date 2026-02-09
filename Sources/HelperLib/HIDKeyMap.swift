// ABOUTME: Maps Unicode characters to USB HID keyboard usage codes (US QWERTY layout).
// ABOUTME: Reference: USB HID Usage Tables, section 10 (Keyboard/Keypad Page 0x07).

/// A single character-to-HID-keycode mapping with required modifier flags.
public struct HIDKeyMapping: Sendable {
    public let keycode: UInt16
    public let modifiers: KeyboardModifier

    public init(keycode: UInt16, modifiers: KeyboardModifier) {
        self.keycode = keycode
        self.modifiers = modifiers
    }
}

/// US QWERTY keyboard layout mapping from characters to HID keycodes.
public enum HIDKeyMap {
    /// Look up the HID keycode and required modifiers for a character.
    /// Returns nil for characters that have no direct HID mapping.
    public static func lookup(_ char: Character) -> HIDKeyMapping? {
        return characterMap[char]
    }

    /// Number of mapped characters.
    public static var count: Int { characterMap.count }

    private static let characterMap: [Character: HIDKeyMapping] = {
        var map = [Character: HIDKeyMapping]()

        // Letters a-z (HID 0x04-0x1D)
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            map[c] = HIDKeyMapping(keycode: UInt16(0x04 + i), modifiers: [])
        }
        // Letters A-Z (same keycodes with shift)
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            map[c] = HIDKeyMapping(keycode: UInt16(0x04 + i), modifiers: .leftShift)
        }

        // Digits 1-9,0 (HID 0x1E-0x27)
        for (i, c) in "1234567890".enumerated() {
            map[c] = HIDKeyMapping(keycode: UInt16(0x1E + i), modifiers: [])
        }

        // Shifted digits
        let shiftedDigits: [(Character, UInt16)] = [
            ("!", 0x1E), ("@", 0x1F), ("#", 0x20), ("$", 0x21),
            ("%", 0x22), ("^", 0x23), ("&", 0x24), ("*", 0x25),
            ("(", 0x26), (")", 0x27),
        ]
        for (c, kc) in shiftedDigits {
            map[c] = HIDKeyMapping(keycode: kc, modifiers: .leftShift)
        }

        // Special characters
        map["\n"] = HIDKeyMapping(keycode: 0x28, modifiers: []) // Return
        map["\r"] = HIDKeyMapping(keycode: 0x28, modifiers: []) // Return
        map["\t"] = HIDKeyMapping(keycode: 0x2B, modifiers: []) // Tab
        map[" "]  = HIDKeyMapping(keycode: 0x2C, modifiers: []) // Space

        // Punctuation (unshifted)
        map["-"]  = HIDKeyMapping(keycode: 0x2D, modifiers: [])
        map["="]  = HIDKeyMapping(keycode: 0x2E, modifiers: [])
        map["["]  = HIDKeyMapping(keycode: 0x2F, modifiers: [])
        map["]"]  = HIDKeyMapping(keycode: 0x30, modifiers: [])
        map["\\"] = HIDKeyMapping(keycode: 0x31, modifiers: [])
        map[";"]  = HIDKeyMapping(keycode: 0x33, modifiers: [])
        map["'"]  = HIDKeyMapping(keycode: 0x34, modifiers: [])
        map["`"]  = HIDKeyMapping(keycode: 0x35, modifiers: [])
        map[","]  = HIDKeyMapping(keycode: 0x36, modifiers: [])
        map["."]  = HIDKeyMapping(keycode: 0x37, modifiers: [])
        map["/"]  = HIDKeyMapping(keycode: 0x38, modifiers: [])

        // ISO section key (HID 0x64): the extra key between left Shift and Z
        // on ISO keyboards. Used by non-US layouts like Canadian-CSA for
        // characters that the Mac and iPhone map differently on this key.
        map["§"]  = HIDKeyMapping(keycode: 0x64, modifiers: [])
        map["±"]  = HIDKeyMapping(keycode: 0x64, modifiers: .leftShift)

        // Punctuation (shifted)
        map["_"]  = HIDKeyMapping(keycode: 0x2D, modifiers: .leftShift)
        map["+"]  = HIDKeyMapping(keycode: 0x2E, modifiers: .leftShift)
        map["{"]  = HIDKeyMapping(keycode: 0x2F, modifiers: .leftShift)
        map["}"]  = HIDKeyMapping(keycode: 0x30, modifiers: .leftShift)
        map["|"]  = HIDKeyMapping(keycode: 0x31, modifiers: .leftShift)
        map[":"]  = HIDKeyMapping(keycode: 0x33, modifiers: .leftShift)
        map["\""] = HIDKeyMapping(keycode: 0x34, modifiers: .leftShift)
        map["~"]  = HIDKeyMapping(keycode: 0x35, modifiers: .leftShift)
        map["<"]  = HIDKeyMapping(keycode: 0x36, modifiers: .leftShift)
        map[">"]  = HIDKeyMapping(keycode: 0x37, modifiers: .leftShift)
        map["?"]  = HIDKeyMapping(keycode: 0x38, modifiers: .leftShift)

        return map
    }()
}
