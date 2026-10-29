// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Reads macOS keyboard layouts with UCKeyTranslate to find which physical key types each character.
// ABOUTME: Builds the per-layout key table that types text on an iPhone whose hardware keyboard is not US QWERTY.

import Carbon
import Foundation

/// One keystroke on a keyboard layout: a macOS virtual keycode, with or without Shift.
public struct LayoutKeyStroke: Equatable, Sendable {
    /// macOS virtual keycode (the physical key, layout-independent).
    public let keycode: UInt16
    /// Whether Shift is held.
    public let shift: Bool

    public init(keycode: UInt16, shift: Bool) {
        self.keycode = keycode
        self.shift = shift
    }
}

/// Reads keyboard layouts to find which physical key types each character.
///
/// CGEvent keycodes are physical keys. Through iPhone Mirroring, the iPhone
/// turns each physical key into a character with its own hardware-keyboard
/// layout, so to type a character the key that produces it *on that layout*
/// must be pressed. `keyTable(layoutData:)` scans a layout with `UCKeyTranslate`
/// and records, for each character it can produce in one keystroke, the key
/// and Shift state that produce it.
public enum LayoutMapper {

    /// macOS source ID of US QWERTY, the layout `CGKeyMap` already encodes.
    public static let usSourceID = "com.apple.keylayout.US"

    /// Virtual keycodes scanned for characters: 0-50 cover the main
    /// alphanumeric and punctuation block, including the ISO section key (0x0A).
    static let scannedKeycodes: ClosedRange<UInt16> = 0...50

    /// Carbon modifier state for Shift (`shiftKey` 0x200 shifted right by 8).
    static let shiftModifierState: UInt32 = 2

    /// Get the `UCKeyboardLayout` data for a keyboard input source by its TIS source ID.
    /// Example source IDs: "com.apple.keylayout.US", "com.apple.keylayout.Canadian-CSA"
    ///
    /// Uses `includeAllInstalled=true` to access macOS-bundled layouts that aren't
    /// currently enabled in the user's input source preferences.
    public static func layoutData(forSourceID sourceID: String) -> Data? {
        let properties: NSDictionary = [
            kTISPropertyInputSourceID as String: sourceID
        ]
        guard let sourceList = TISCreateInputSourceList(properties, true),
              let sources = sourceList.takeRetainedValue() as? [TISInputSource],
              let source = sources.first
        else {
            return nil
        }
        return extractLayoutData(from: source)
    }

    /// Full TIS source ID for a layout name: `"Canadian-CSA"` and
    /// `"com.apple.keylayout.Canadian-CSA"` both give the latter.
    public static func sourceID(forLayout layout: String) -> String {
        layout.hasPrefix("com.apple.keylayout.") ? layout : "com.apple.keylayout.\(layout)"
    }

    /// Whether `layout` names US QWERTY (or nothing), which needs no key table.
    public static func isUSLayout(_ layout: String) -> Bool {
        layout.isEmpty || sourceID(forLayout: layout) == usSourceID
    }

    /// Find the iPhone's keyboard layout when it is not US QWERTY.
    ///
    /// Reads the layout name from `EnvConfig.keyboardLayout` which resolves
    /// from settings.json (set by `mirroir-mcp configure`) or the
    /// `IPHONE_KEYBOARD_LAYOUT` environment variable.
    ///
    /// Pass an explicit `layout` to override config lookup (used by tests).
    /// Returns nil when the layout is empty or US QWERTY, or when macOS has no
    /// layout by that name.
    public static func findNonUSLayout(layout override: String? = nil) -> (sourceID: String, layoutData: Data)? {
        let layout = override ?? EnvConfig.keyboardLayout
        guard !isUSLayout(layout) else { return nil }
        let fullID = sourceID(forLayout: layout)
        return layoutData(forSourceID: fullID).map { (fullID, $0) }
    }

    /// Build the table of single keystrokes that type each character on a layout.
    ///
    /// Scans every key in `scannedKeycodes`, unshifted then shifted, so a
    /// character reachable both ways is typed with the simpler unshifted key.
    /// Dead keys (a key that only starts a composition, like `^` on
    /// Canadian-CSA) are left out: pressing one types nothing by itself and
    /// changes the next character; `deadKeyCompositions(layoutData:)` covers
    /// the characters they compose.
    public static func keyTable(layoutData: Data) -> [Character: LayoutKeyStroke] {
        var table = [Character: LayoutKeyStroke]()
        for shift in [false, true] {
            let modifiers = shift ? shiftModifierState : 0
            for keycode in scannedKeycodes {
                guard !isDeadKey(keycode, modifiers: modifiers, layoutData: layoutData),
                      let char = translateKeycode(
                          keycode, modifiers: modifiers, layoutData: layoutData),
                      table[char] == nil
                else { continue }
                table[char] = LayoutKeyStroke(keycode: keycode, shift: shift)
            }
        }
        return table
    }

    /// Build the table of two-keystroke dead-key compositions on a layout.
    ///
    /// A dead key (e.g. `^` on Canadian-CSA, keycode 0x21) types nothing by
    /// itself; the next key completes the character (`^` then `e` gives `ê`).
    /// For every dead key, unshifted then shifted, this presses each scanned
    /// key after it and records the pair when the two compose to exactly one
    /// character. A pair that does not combine emits the accent and the key
    /// separately and is left out. The first pair found for a character wins.
    public static func deadKeyCompositions(layoutData: Data) -> [Character: [LayoutKeyStroke]] {
        var table = [Character: [LayoutKeyStroke]]()
        for deadShift in [false, true] {
            let deadModifiers = deadShift ? shiftModifierState : 0
            for deadKeycode in scannedKeycodes
            where isDeadKey(deadKeycode, modifiers: deadModifiers, layoutData: layoutData) {
                let dead = LayoutKeyStroke(keycode: deadKeycode, shift: deadShift)
                for baseShift in [false, true] {
                    for baseKeycode in scannedKeycodes {
                        let base = LayoutKeyStroke(keycode: baseKeycode, shift: baseShift)
                        guard let char = composedCharacter(dead: dead, base: base, layoutData: layoutData),
                              table[char] == nil
                        else { continue }
                        table[char] = [dead, base]
                    }
                }
            }
        }
        return table
    }

    /// The single character `dead` followed by `base` composes to, or nil
    /// when the pair emits anything other than exactly one character.
    static func composedCharacter(
        dead: LayoutKeyStroke, base: LayoutKeyStroke, layoutData: Data
    ) -> Character? {
        var deadKeyState: UInt32 = 0
        _ = translatedText(dead.keycode, modifiers: dead.shift ? shiftModifierState : 0,
                           layoutData: layoutData, options: 0, deadKeyState: &deadKeyState)
        guard deadKeyState != 0,
              let text = translatedText(base.keycode, modifiers: base.shift ? shiftModifierState : 0,
                                        layoutData: layoutData, options: 0, deadKeyState: &deadKeyState),
              text.count == 1
        else { return nil }
        return text.first
    }

    /// Translate a single virtual keycode + modifier state to a character
    /// using the provided keyboard layout data.
    ///
    /// Uses `kUCKeyTranslateNoDeadKeysMask` to get the immediate character
    /// without dead-key composition.
    public static func translateKeycode(
        _ keycode: UInt16, modifiers: UInt32, layoutData: Data
    ) -> Character? {
        var deadKeyState: UInt32 = 0
        return translate(keycode, modifiers: modifiers, layoutData: layoutData,
                         options: OptionBits(kUCKeyTranslateNoDeadKeysMask),
                         deadKeyState: &deadKeyState)
    }

    /// Whether `keycode` with `modifiers` is a dead key on the layout: with
    /// dead-key processing on, it produces no character and leaves a pending
    /// composition state.
    public static func isDeadKey(
        _ keycode: UInt16, modifiers: UInt32, layoutData: Data
    ) -> Bool {
        var deadKeyState: UInt32 = 0
        let char = translate(keycode, modifiers: modifiers, layoutData: layoutData,
                             options: 0, deadKeyState: &deadKeyState)
        return char == nil && deadKeyState != 0
    }

    // MARK: - Private

    private static func translate(
        _ keycode: UInt16, modifiers: UInt32, layoutData: Data,
        options: OptionBits, deadKeyState: inout UInt32
    ) -> Character? {
        translatedText(keycode, modifiers: modifiers, layoutData: layoutData,
                       options: options, deadKeyState: &deadKeyState)?.first
    }

    /// Every character one key press emits. A dead key followed by a key it
    /// does not combine with emits two (`^` then `x` gives `"^x"`).
    private static func translatedText(
        _ keycode: UInt16, modifiers: UInt32, layoutData: Data,
        options: OptionBits, deadKeyState: inout UInt32
    ) -> String? {
        return layoutData.withUnsafeBytes { buffer in
            guard let layoutPtr = buffer.baseAddress?
                .assumingMemoryBound(to: UCKeyboardLayout.self)
            else {
                return nil
            }

            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0

            // Keyboard type 0 (ANSI default) works for all standard layouts.
            // LMGetKbdType() reads low-memory globals that may not be initialized
            // in headless/test contexts.
            let status = UCKeyTranslate(
                layoutPtr,
                keycode,
                UInt16(kUCKeyActionDown),
                modifiers,
                0,
                options,
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )

            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// Extract UCKeyboardLayout data from a TIS input source.
    private static func extractLayoutData(from source: TISInputSource) -> Data? {
        guard let rawPtr = TISGetInputSourceProperty(
            source, kTISPropertyUnicodeKeyLayoutData
        ) else {
            return nil
        }
        let cfData = Unmanaged<CFData>.fromOpaque(rawPtr).takeUnretainedValue()
        return cfData as Data
    }
}
