// ABOUTME: Maps special key names to USB HID keycodes for the Karabiner virtual keyboard.
// ABOUTME: Used by the helper daemon to send special keys (Return, Escape, arrows) via HID reports.

/// Maps special key name strings to USB HID keycodes (Usage Page 0x07) for use
/// with `KarabinerClient.typeKey()`. Complements `HIDKeyMap` (which maps printable
/// characters) by handling navigation and editing keys.
public enum HIDSpecialKeyMap {

    /// USB HID keycodes for special keys (Usage Page 0x07).
    private static let keyMap: [String: UInt16] = [
        "return": 0x28,  // Keyboard Return (Enter)
        "escape": 0x29,  // Keyboard Escape
        "delete": 0x2A,  // Keyboard Backspace / Delete
        "tab": 0x2B,     // Keyboard Tab
        "space": 0x2C,   // Keyboard Spacebar
        "right": 0x4F,   // Keyboard Right Arrow
        "left": 0x50,    // Keyboard Left Arrow
        "down": 0x51,    // Keyboard Down Arrow
        "up": 0x52,      // Keyboard Up Arrow
    ]

    /// Look up the USB HID keycode for a special key name.
    /// Key names are case-sensitive and lowercase (e.g., "return", "escape").
    /// Returns nil for unknown key names.
    public static func hidKeyCode(for name: String) -> UInt16? {
        keyMap[name]
    }

    /// All supported key names, sorted alphabetically.
    public static var supportedKeys: [String] {
        keyMap.keys.sorted()
    }

    /// Maps modifier name strings to `KeyboardModifier` values for HID reports.
    private static let modifierMap: [String: KeyboardModifier] = [
        "command": .leftCommand,
        "shift": .leftShift,
        "option": .leftOption,
        "control": .leftControl,
    ]

    /// Convert modifier name strings to a combined `KeyboardModifier` bitmask.
    /// Unknown modifier names are silently ignored.
    public static func modifiers(from names: [String]) -> KeyboardModifier {
        var result: KeyboardModifier = []
        for name in names {
            if let mod = modifierMap[name] {
                result.insert(mod)
            }
        }
        return result
    }

    /// All supported modifier names, sorted alphabetically.
    public static var supportedModifiers: [String] {
        modifierMap.keys.sorted()
    }
}
