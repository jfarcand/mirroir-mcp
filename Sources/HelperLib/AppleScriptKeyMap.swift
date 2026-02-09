// ABOUTME: Maps key names to macOS virtual key codes and generates AppleScript for key presses.
// ABOUTME: Used by the MCP server to send special keys (Return, Escape, arrows) to iPhone Mirroring.

/// Maps key name strings to macOS virtual key codes for use with AppleScript `key code`.
public enum AppleScriptKeyMap {

    /// macOS virtual key codes for special keys (same codes as CGEvent virtualKey).
    private static let keyMap: [String: UInt16] = [
        "return": 36,
        "escape": 53,
        "tab": 48,
        "delete": 51,
        "space": 49,
        "up": 126,
        "down": 125,
        "left": 123,
        "right": 124,
    ]

    /// Look up the macOS virtual key code for a key name.
    /// Key names are case-sensitive and lowercase (e.g., "return", "escape").
    /// Returns nil for unknown key names.
    public static func keyCode(for name: String) -> UInt16? {
        keyMap[name]
    }

    /// All supported key names, sorted alphabetically.
    public static var supportedKeys: [String] {
        keyMap.keys.sorted()
    }

    /// Build an AppleScript that activates iPhone Mirroring and sends a key press.
    /// - Parameters:
    ///   - keyCode: macOS virtual key code (from `keyCode(for:)`)
    ///   - modifiers: Optional modifier names ("command", "shift", "option", "control")
    /// - Returns: AppleScript source string ready for NSAppleScript execution
    public static func buildKeyPressScript(keyCode: UInt16, modifiers: [String] = []) -> String {
        let modifierClause: String
        if modifiers.isEmpty {
            modifierClause = ""
        } else {
            let modifierList = modifiers.compactMap { modifierMapping[$0] }.joined(separator: ", ")
            modifierClause = " using {\(modifierList)}"
        }

        return """
            tell application "System Events"
                set prevApp to name of first process whose frontmost is true
                tell process "iPhone Mirroring"
                    set frontmost to true
                end tell
                delay 0.1
                key code \(keyCode)\(modifierClause)
                delay 0.05
                tell process prevApp
                    set frontmost to true
                end tell
            end tell
            """
    }

    /// AppleScript modifier name mapping.
    private static let modifierMapping: [String: String] = [
        "command": "command down",
        "shift": "shift down",
        "option": "option down",
        "control": "control down",
    ]

    /// Escape a string for safe embedding in an AppleScript `keystroke "..."` command.
    /// Handles backslashes (doubled) and double quotes (backslash-escaped).
    public static func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
