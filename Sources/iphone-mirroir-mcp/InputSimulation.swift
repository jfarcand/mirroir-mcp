// ABOUTME: Simulates user input (tap, swipe, keyboard) on the iPhone Mirroring window.
// ABOUTME: Delegates to the privileged Karabiner helper daemon for taps and swipes.

import AppKit
import CoreGraphics
import Foundation
import HelperLib

/// Result of a type operation, including any characters the helper couldn't map.
struct TypeResult {
    let success: Bool
    let skippedCharacters: String
    let warning: String?
    let error: String?
}

/// Simulates touch and keyboard input on the iPhone Mirroring window.
/// All coordinates are relative to the mirroring window's content area.
///
/// Requires the Karabiner helper daemon for tap/swipe operations.
/// Keyboard input uses AppleScript via System Events (no helper needed).
final class InputSimulation: @unchecked Sendable {
    private let bridge: MirroringBridge
    let helperClient = HelperClient()

    init(bridge: MirroringBridge) {
        self.bridge = bridge
    }

    /// Tap at a position relative to the mirroring window.
    /// Returns nil on success, or an error message if the helper is unavailable.
    func tap(x: Double, y: Double) -> String? {
        guard let info = bridge.getWindowInfo() else {
            return "iPhone Mirroring window not found"
        }

        guard helperClient.isAvailable else {
            return helperClient.unavailableMessage
        }

        let screenX = info.position.x + CGFloat(x)
        let screenY = info.position.y + CGFloat(y)

        if helperClient.click(x: Double(screenX), y: Double(screenY)) {
            return nil // success
        }
        return "Helper click failed"
    }

    /// Swipe from one point to another relative to the mirroring window.
    /// Returns nil on success, or an error message if the helper is unavailable.
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int = 300)
        -> String?
    {
        guard let info = bridge.getWindowInfo() else {
            return "iPhone Mirroring window not found"
        }

        guard helperClient.isAvailable else {
            return helperClient.unavailableMessage
        }

        let startX = Double(info.position.x) + fromX
        let startY = Double(info.position.y) + fromY
        let endX = Double(info.position.x) + toX
        let endY = Double(info.position.y) + toY

        if helperClient.swipe(fromX: startX, fromY: startY,
                              toX: endX, toY: endY,
                              durationMs: durationMs) {
            return nil // success
        }
        return "Helper swipe failed"
    }

    /// Type text using AppleScript keystroke via System Events.
    /// First activates iPhone Mirroring to make it the frontmost app,
    /// then sends keystrokes through System Events which routes to the frontmost app.
    func typeText(_ text: String) -> TypeResult {
        let escaped = AppleScriptKeyMap.escapeForAppleScript(text)

        let script = NSAppleScript(source: """
            tell application "System Events"
                tell process "iPhone Mirroring"
                    set frontmost to true
                end tell
                delay 0.5
                keystroke "\(escaped)"
            end tell
            """)

        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        if let err = errorInfo {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
            return TypeResult(success: false, skippedCharacters: "",
                              warning: nil, error: msg)
        }

        return TypeResult(success: true, skippedCharacters: "",
                          warning: nil, error: nil)
    }

    /// Send a special key press (Return, Escape, arrows, etc.) with optional modifiers.
    /// Uses AppleScript `key code` via System Events — the same proven approach as typeText.
    func pressKeyViaAppleScript(keyName: String, modifiers: [String] = []) -> TypeResult {
        guard let code = AppleScriptKeyMap.keyCode(for: keyName) else {
            let supported = AppleScriptKeyMap.supportedKeys.joined(separator: ", ")
            return TypeResult(
                success: false, skippedCharacters: "",
                warning: nil,
                error: "Unknown key: \"\(keyName)\". Supported keys: \(supported)"
            )
        }

        let scriptSource = AppleScriptKeyMap.buildKeyPressScript(
            keyCode: code, modifiers: modifiers
        )
        let script = NSAppleScript(source: scriptSource)

        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        if let err = errorInfo {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
            return TypeResult(success: false, skippedCharacters: "",
                              warning: nil, error: msg)
        }

        return TypeResult(success: true, skippedCharacters: "",
                          warning: nil, error: nil)
    }
}
