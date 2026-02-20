// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Maps Unicode characters to USB HID keyboard usage codes (US QWERTY layout).
// ABOUTME: Reference: USB HID Usage Tables, section 10 (Keyboard/Keypad Page 0x07).

/// A single character-to-HID-keycode mapping with required modifier flags.
public struct HIDKeyMapping: Sendable, Equatable {
    public let keycode: UInt16
    public let modifiers: KeyboardModifier

    public init(keycode: UInt16, modifiers: KeyboardModifier) {
        self.keycode = keycode
        self.modifiers = modifiers
    }
}

/// A sequence of HID key presses needed to produce a single character.
/// Single-key characters have one step; dead-key accented characters have two
/// (dead-key trigger + base character).
public struct HIDKeySequence: Sendable, Equatable {
    public let steps: [HIDKeyMapping]

    public init(steps: [HIDKeyMapping]) {
        self.steps = steps
    }
}

/// US QWERTY keyboard layout mapping from characters to HID keycodes.
public enum HIDKeyMap {
    /// Look up the HID keycode and required modifiers for a character.
    /// Returns nil for characters that have no direct HID mapping.
    public static func lookup(_ char: Character) -> HIDKeyMapping? {
        return characterMap[char]
    }

    /// Look up the full key sequence needed to type a character.
    /// Returns a 1-step sequence for regular characters, a 2-step sequence
    /// for dead-key accented characters (e.g., Option+e then e = é),
    /// or nil for characters with no HID mapping (emoji, CJK, etc.).
    public static func lookupSequence(_ char: Character) -> HIDKeySequence? {
        if let mapping = characterMap[char] {
            return HIDKeySequence(steps: [mapping])
        }
        if let sequence = deadKeyMap[char] {
            return sequence
        }
        return nil
    }

    /// Number of directly mapped characters (excludes dead-key sequences).
    public static var count: Int { characterMap.count }

    /// Number of characters reachable via dead-key sequences.
    public static var deadKeyCount: Int { deadKeyMap.count }

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

    // MARK: - Dead-Key Sequences

    /// Characters that require a two-step dead-key sequence on US QWERTY.
    /// Step 1: Press the dead-key trigger (Option + key).
    /// Step 2: Press the base character (with Shift if uppercase).
    ///
    /// Also includes single-step Option characters like ç (Option+c).
    ///
    /// Dead-key families on US QWERTY:
    /// - Acute (Option+e):     é á í ó ú and uppercase
    /// - Grave (Option+`):     è à ì ò ù and uppercase
    /// - Umlaut (Option+u):    ü ö ä ë ï ÿ and uppercase
    /// - Circumflex (Option+i): ê â î ô û and uppercase
    /// - Tilde (Option+n):     ñ ã õ and uppercase
    private static let deadKeyMap: [Character: HIDKeySequence] = {
        var map = [Character: HIDKeySequence]()

        // Dead-key trigger keycodes (US QWERTY)
        let optionE = HIDKeyMapping(keycode: 0x08, modifiers: .leftOption)  // Option+e (acute)
        let optionGrave = HIDKeyMapping(keycode: 0x35, modifiers: .leftOption)  // Option+` (grave)
        let optionU = HIDKeyMapping(keycode: 0x18, modifiers: .leftOption)  // Option+u (umlaut)
        let optionI = HIDKeyMapping(keycode: 0x0C, modifiers: .leftOption)  // Option+i (circumflex)
        let optionN = HIDKeyMapping(keycode: 0x11, modifiers: .leftOption)  // Option+n (tilde)

        // Helper to add a dead-key pair (lowercase + uppercase)
        func addPair(
            _ lower: Character, _ upper: Character,
            trigger: HIDKeyMapping, baseKeycode: UInt16
        ) {
            map[lower] = HIDKeySequence(steps: [
                trigger,
                HIDKeyMapping(keycode: baseKeycode, modifiers: []),
            ])
            map[upper] = HIDKeySequence(steps: [
                trigger,
                HIDKeyMapping(keycode: baseKeycode, modifiers: .leftShift),
            ])
        }

        // Acute accent (Option+e, then base)
        addPair("é", "É", trigger: optionE, baseKeycode: 0x08)  // e
        addPair("á", "Á", trigger: optionE, baseKeycode: 0x04)  // a
        addPair("í", "Í", trigger: optionE, baseKeycode: 0x0C)  // i
        addPair("ó", "Ó", trigger: optionE, baseKeycode: 0x12)  // o
        addPair("ú", "Ú", trigger: optionE, baseKeycode: 0x18)  // u

        // Grave accent (Option+`, then base)
        addPair("è", "È", trigger: optionGrave, baseKeycode: 0x08)  // e
        addPair("à", "À", trigger: optionGrave, baseKeycode: 0x04)  // a
        addPair("ì", "Ì", trigger: optionGrave, baseKeycode: 0x0C)  // i
        addPair("ò", "Ò", trigger: optionGrave, baseKeycode: 0x12)  // o
        addPair("ù", "Ù", trigger: optionGrave, baseKeycode: 0x18)  // u

        // Umlaut / diaeresis (Option+u, then base)
        addPair("ü", "Ü", trigger: optionU, baseKeycode: 0x18)  // u
        addPair("ö", "Ö", trigger: optionU, baseKeycode: 0x12)  // o
        addPair("ä", "Ä", trigger: optionU, baseKeycode: 0x04)  // a
        addPair("ë", "Ë", trigger: optionU, baseKeycode: 0x08)  // e
        addPair("ï", "Ï", trigger: optionU, baseKeycode: 0x0C)  // i
        addPair("ÿ", "Ÿ", trigger: optionU, baseKeycode: 0x1C)  // y

        // Circumflex (Option+i, then base)
        addPair("ê", "Ê", trigger: optionI, baseKeycode: 0x08)  // e
        addPair("â", "Â", trigger: optionI, baseKeycode: 0x04)  // a
        addPair("î", "Î", trigger: optionI, baseKeycode: 0x0C)  // i
        addPair("ô", "Ô", trigger: optionI, baseKeycode: 0x12)  // o
        addPair("û", "Û", trigger: optionI, baseKeycode: 0x18)  // u

        // Tilde (Option+n, then base)
        addPair("ñ", "Ñ", trigger: optionN, baseKeycode: 0x11)  // n
        addPair("ã", "Ã", trigger: optionN, baseKeycode: 0x04)  // a
        addPair("õ", "Õ", trigger: optionN, baseKeycode: 0x12)  // o

        // Direct Option characters (single-step, no dead key)
        map["ç"] = HIDKeySequence(steps: [
            HIDKeyMapping(keycode: 0x06, modifiers: .leftOption),  // Option+c
        ])
        map["Ç"] = HIDKeySequence(steps: [
            HIDKeyMapping(keycode: 0x06, modifiers: [.leftOption, .leftShift]),  // Option+Shift+c
        ])

        return map
    }()
}
