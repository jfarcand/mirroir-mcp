// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Maps Unicode characters to macOS virtual keycodes (Carbon kVK_*) for CGEvent keyboard input.
// ABOUTME: Reference: Carbon Events.h virtual key codes (same codes used by CGEvent).

import CoreGraphics

/// A single character-to-virtual-keycode mapping with required CGEvent modifier flags.
struct CGKeyMapping: Sendable, Equatable {
    let keycode: UInt16
    let flags: CGEventFlags
}

extension CGEventFlags: @retroactive Equatable {
    public static func == (lhs: CGEventFlags, rhs: CGEventFlags) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

/// A sequence of CGEvent key presses needed to produce a single character.
/// Single-key characters have one step; dead-key accented characters have two
/// (dead-key trigger + base character).
struct CGKeySequence: Sendable, Equatable {
    let steps: [CGKeyMapping]
}

/// US QWERTY keyboard layout mapping from characters to macOS virtual keycodes.
/// Uses Carbon virtual keycodes (kVK_*) for CGEvent keyboard posting.
enum CGKeyMap {

    /// Look up the macOS virtual keycode and required modifiers for a character.
    /// Returns nil for characters that have no direct mapping.
    static func lookup(_ char: Character) -> CGKeyMapping? {
        characterMap[char]
    }

    /// Look up the full key sequence needed to type a character.
    /// Returns a 1-step sequence for regular characters, a 2-step sequence
    /// for dead-key accented characters (e.g., Option+e then e = é),
    /// or nil for characters with no mapping (emoji, CJK, etc.).
    static func lookupSequence(_ char: Character) -> CGKeySequence? {
        if let mapping = characterMap[char] {
            return CGKeySequence(steps: [mapping])
        }
        if let sequence = deadKeyMap[char] {
            return sequence
        }
        return nil
    }

    /// Number of directly mapped characters (excludes dead-key sequences).
    static var count: Int { characterMap.count }

    /// Number of characters reachable via dead-key sequences.
    static var deadKeyCount: Int { deadKeyMap.count }

    // MARK: - macOS Virtual Keycodes (Carbon Events.h)

    // Letters (kVK_ANSI_*)
    private static let kA: UInt16 = 0x00
    private static let kS: UInt16 = 0x01
    private static let kD: UInt16 = 0x02
    private static let kF: UInt16 = 0x03
    private static let kH: UInt16 = 0x04
    private static let kG: UInt16 = 0x05
    private static let kZ: UInt16 = 0x06
    private static let kX: UInt16 = 0x07
    private static let kC: UInt16 = 0x08
    private static let kV: UInt16 = 0x09
    private static let kB: UInt16 = 0x0B
    private static let kQ: UInt16 = 0x0C
    private static let kW: UInt16 = 0x0D
    private static let kE: UInt16 = 0x0E
    private static let kR: UInt16 = 0x0F
    private static let kY: UInt16 = 0x10
    private static let kT: UInt16 = 0x11
    private static let k1: UInt16 = 0x12
    private static let k2: UInt16 = 0x13
    private static let k3: UInt16 = 0x14
    private static let k4: UInt16 = 0x15
    private static let k6: UInt16 = 0x16
    private static let k5: UInt16 = 0x17
    private static let kEqual: UInt16 = 0x18
    private static let k9: UInt16 = 0x19
    private static let k7: UInt16 = 0x1A
    private static let kMinus: UInt16 = 0x1B
    private static let k8: UInt16 = 0x1C
    private static let k0: UInt16 = 0x1D
    private static let kRightBracket: UInt16 = 0x1E
    private static let kO: UInt16 = 0x1F
    private static let kU: UInt16 = 0x20
    private static let kLeftBracket: UInt16 = 0x21
    private static let kI: UInt16 = 0x22
    private static let kP: UInt16 = 0x23
    private static let kL: UInt16 = 0x25
    private static let kJ: UInt16 = 0x26
    private static let kQuote: UInt16 = 0x27
    private static let kK: UInt16 = 0x28
    private static let kSemicolon: UInt16 = 0x29
    private static let kBackslash: UInt16 = 0x2A
    private static let kComma: UInt16 = 0x2B
    private static let kSlash: UInt16 = 0x2C
    private static let kN: UInt16 = 0x2D
    private static let kM: UInt16 = 0x2E
    private static let kPeriod: UInt16 = 0x2F
    private static let kGrave: UInt16 = 0x32
    private static let kReturn: UInt16 = 0x24
    private static let kTab: UInt16 = 0x30
    private static let kSpace: UInt16 = 0x31
    private static let kDelete: UInt16 = 0x33
    private static let kEscape: UInt16 = 0x35

    // MARK: - Character Map

    /// Control characters and the keys that type them on every layout. Return
    /// and Tab sit on the same virtual keycode whatever the layout, and a
    /// layout's own key table never lists them, so a non-US layout takes them
    /// from here instead of routing them through the clipboard.
    static let layoutIndependentKeys: [Character: CGKeyMapping] = [
        "\n": CGKeyMapping(keycode: kReturn, flags: CGEventFlags()),
        "\r": CGKeyMapping(keycode: kReturn, flags: CGEventFlags()),
        "\t": CGKeyMapping(keycode: kTab, flags: CGEventFlags()),
    ]

    private static let characterMap: [Character: CGKeyMapping] = {
        var map = [Character: CGKeyMapping]()

        let none = CGEventFlags()

        // Letters a-z (each has a unique virtual keycode)
        let letterCodes: [(Character, UInt16)] = [
            ("a", kA), ("b", kB), ("c", kC), ("d", kD), ("e", kE),
            ("f", kF), ("g", kG), ("h", kH), ("i", kI), ("j", kJ),
            ("k", kK), ("l", kL), ("m", kM), ("n", kN), ("o", kO),
            ("p", kP), ("q", kQ), ("r", kR), ("s", kS), ("t", kT),
            ("u", kU), ("v", kV), ("w", kW), ("x", kX), ("y", kY),
            ("z", kZ),
        ]
        for (c, kc) in letterCodes {
            map[c] = CGKeyMapping(keycode: kc, flags: none)
        }

        // Letters A-Z (same keycodes with shift)
        let upperCodes: [(Character, UInt16)] = [
            ("A", kA), ("B", kB), ("C", kC), ("D", kD), ("E", kE),
            ("F", kF), ("G", kG), ("H", kH), ("I", kI), ("J", kJ),
            ("K", kK), ("L", kL), ("M", kM), ("N", kN), ("O", kO),
            ("P", kP), ("Q", kQ), ("R", kR), ("S", kS), ("T", kT),
            ("U", kU), ("V", kV), ("W", kW), ("X", kX), ("Y", kY),
            ("Z", kZ),
        ]
        for (c, kc) in upperCodes {
            map[c] = CGKeyMapping(keycode: kc, flags: .maskShift)
        }

        // Digits 0-9
        let digitCodes: [(Character, UInt16)] = [
            ("1", k1), ("2", k2), ("3", k3), ("4", k4), ("5", k5),
            ("6", k6), ("7", k7), ("8", k8), ("9", k9), ("0", k0),
        ]
        for (c, kc) in digitCodes {
            map[c] = CGKeyMapping(keycode: kc, flags: none)
        }

        // Shifted digits
        let shiftedDigits: [(Character, UInt16)] = [
            ("!", k1), ("@", k2), ("#", k3), ("$", k4), ("%", k5),
            ("^", k6), ("&", k7), ("*", k8), ("(", k9), (")", k0),
        ]
        for (c, kc) in shiftedDigits {
            map[c] = CGKeyMapping(keycode: kc, flags: .maskShift)
        }

        // Special characters
        map.merge(layoutIndependentKeys) { current, _ in current }
        map[" "]  = CGKeyMapping(keycode: kSpace, flags: none)

        // Punctuation (unshifted)
        map["-"]  = CGKeyMapping(keycode: kMinus, flags: none)
        map["="]  = CGKeyMapping(keycode: kEqual, flags: none)
        map["["]  = CGKeyMapping(keycode: kLeftBracket, flags: none)
        map["]"]  = CGKeyMapping(keycode: kRightBracket, flags: none)
        map["\\"] = CGKeyMapping(keycode: kBackslash, flags: none)
        map[";"]  = CGKeyMapping(keycode: kSemicolon, flags: none)
        map["'"]  = CGKeyMapping(keycode: kQuote, flags: none)
        map["`"]  = CGKeyMapping(keycode: kGrave, flags: none)
        map[","]  = CGKeyMapping(keycode: kComma, flags: none)
        map["."]  = CGKeyMapping(keycode: kPeriod, flags: none)
        map["/"]  = CGKeyMapping(keycode: kSlash, flags: none)

        // Punctuation (shifted)
        map["_"]  = CGKeyMapping(keycode: kMinus, flags: .maskShift)
        map["+"]  = CGKeyMapping(keycode: kEqual, flags: .maskShift)
        map["{"]  = CGKeyMapping(keycode: kLeftBracket, flags: .maskShift)
        map["}"]  = CGKeyMapping(keycode: kRightBracket, flags: .maskShift)
        map["|"]  = CGKeyMapping(keycode: kBackslash, flags: .maskShift)
        map[":"]  = CGKeyMapping(keycode: kSemicolon, flags: .maskShift)
        map["\""] = CGKeyMapping(keycode: kQuote, flags: .maskShift)
        map["~"]  = CGKeyMapping(keycode: kGrave, flags: .maskShift)
        map["<"]  = CGKeyMapping(keycode: kComma, flags: .maskShift)
        map[">"]  = CGKeyMapping(keycode: kPeriod, flags: .maskShift)
        map["?"]  = CGKeyMapping(keycode: kSlash, flags: .maskShift)

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
    /// - Grave (Option+`):     è à ì ò ù
    /// - Umlaut (Option+u):    ü ö ä ë ï ÿ
    /// - Circumflex (Option+i): ê â î ô û
    /// - Tilde (Option+n):     ñ ã õ
    private static let deadKeyMap: [Character: CGKeySequence] = {
        var map = [Character: CGKeySequence]()

        // Dead-key trigger keycodes (US QWERTY, macOS virtual keycodes)
        let optionE = CGKeyMapping(keycode: kE, flags: .maskAlternate)     // Option+e (acute)
        let optionGrave = CGKeyMapping(keycode: kGrave, flags: .maskAlternate) // Option+` (grave)
        let optionU = CGKeyMapping(keycode: kU, flags: .maskAlternate)     // Option+u (umlaut)
        let optionI = CGKeyMapping(keycode: kI, flags: .maskAlternate)     // Option+i (circumflex)
        let optionN = CGKeyMapping(keycode: kN, flags: .maskAlternate)     // Option+n (tilde)

        let none = CGEventFlags()

        // Helper to add a dead-key pair (lowercase + uppercase)
        func addPair(
            _ lower: Character, _ upper: Character,
            trigger: CGKeyMapping, baseKeycode: UInt16
        ) {
            map[lower] = CGKeySequence(steps: [
                trigger,
                CGKeyMapping(keycode: baseKeycode, flags: none),
            ])
            map[upper] = CGKeySequence(steps: [
                trigger,
                CGKeyMapping(keycode: baseKeycode, flags: .maskShift),
            ])
        }

        // Acute accent (Option+e, then base)
        addPair("é", "É", trigger: optionE, baseKeycode: kE)
        addPair("á", "Á", trigger: optionE, baseKeycode: kA)
        addPair("í", "Í", trigger: optionE, baseKeycode: kI)
        addPair("ó", "Ó", trigger: optionE, baseKeycode: kO)
        addPair("ú", "Ú", trigger: optionE, baseKeycode: kU)

        // Grave accent (Option+`, then base)
        addPair("è", "È", trigger: optionGrave, baseKeycode: kE)
        addPair("à", "À", trigger: optionGrave, baseKeycode: kA)
        addPair("ì", "Ì", trigger: optionGrave, baseKeycode: kI)
        addPair("ò", "Ò", trigger: optionGrave, baseKeycode: kO)
        addPair("ù", "Ù", trigger: optionGrave, baseKeycode: kU)

        // Umlaut / diaeresis (Option+u, then base)
        addPair("ü", "Ü", trigger: optionU, baseKeycode: kU)
        addPair("ö", "Ö", trigger: optionU, baseKeycode: kO)
        addPair("ä", "Ä", trigger: optionU, baseKeycode: kA)
        addPair("ë", "Ë", trigger: optionU, baseKeycode: kE)
        addPair("ï", "Ï", trigger: optionU, baseKeycode: kI)
        addPair("ÿ", "Ÿ", trigger: optionU, baseKeycode: kY)

        // Circumflex (Option+i, then base)
        addPair("ê", "Ê", trigger: optionI, baseKeycode: kE)
        addPair("â", "Â", trigger: optionI, baseKeycode: kA)
        addPair("î", "Î", trigger: optionI, baseKeycode: kI)
        addPair("ô", "Ô", trigger: optionI, baseKeycode: kO)
        addPair("û", "Û", trigger: optionI, baseKeycode: kU)

        // Tilde (Option+n, then base)
        addPair("ñ", "Ñ", trigger: optionN, baseKeycode: kN)
        addPair("ã", "Ã", trigger: optionN, baseKeycode: kA)
        addPair("õ", "Õ", trigger: optionN, baseKeycode: kO)

        // Direct Option characters (single-step, no dead key)
        map["ç"] = CGKeySequence(steps: [
            CGKeyMapping(keycode: kC, flags: .maskAlternate),
        ])
        map["Ç"] = CGKeySequence(steps: [
            CGKeyMapping(keycode: kC, flags: [.maskAlternate, .maskShift]),
        ])

        return map
    }()
}
