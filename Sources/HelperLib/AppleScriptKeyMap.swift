// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Maps key names to macOS virtual key codes and generates AppleScript for key presses.
// ABOUTME: Used by the MCP server to send special keys (Return, Escape, arrows) to iPhone Mirroring.

/// Maps key name strings to macOS virtual key codes for use with AppleScript `key code`.
public enum AppleScriptKeyMap {

    /// macOS virtual key codes for special keys (same codes as CGEvent virtualKey).
    /// Uses `KeyName` as key type for compile-time exhaustive coverage.
    private static let keyMap: [KeyName: UInt16] = [
        .return: 36,
        .escape: 53,
        .tab: 48,
        .delete: 51,
        .space: 49,
        .up: 126,
        .down: 125,
        .left: 123,
        .right: 124,
    ]

    /// Look up the macOS virtual key code for a key name string.
    /// Key names are case-sensitive and lowercase (e.g., "return", "escape").
    /// Returns nil for unknown key names.
    public static func keyCode(for name: String) -> UInt16? {
        guard let key = KeyName(rawValue: name) else { return nil }
        return keyMap[key]
    }

    /// Look up the macOS virtual key code for a typed key name.
    public static func keyCode(for key: KeyName) -> UInt16? {
        keyMap[key]
    }

    /// All supported key names, sorted alphabetically.
    public static var supportedKeys: [String] {
        KeyName.sortedNames
    }

    /// Escape a string for safe embedding in an AppleScript `keystroke "..."` command.
    /// Handles backslashes (doubled) and double quotes (backslash-escaped).
    public static func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
