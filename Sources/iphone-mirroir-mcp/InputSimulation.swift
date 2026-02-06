// ABOUTME: Simulates user input (tap, swipe, keyboard) on the iPhone Mirroring window.
// ABOUTME: Uses CGEvent APIs to send mouse and keyboard events at window-relative coordinates.

import CoreGraphics
import Foundation

/// Simulates touch and keyboard input on the iPhone Mirroring window.
/// All coordinates are relative to the mirroring window's content area.
final class InputSimulation: @unchecked Sendable {
    private let bridge: MirroringBridge

    init(bridge: MirroringBridge) {
        self.bridge = bridge
    }

    /// Tap at a position relative to the mirroring window.
    /// - Parameters:
    ///   - x: X coordinate relative to window's left edge
    ///   - y: Y coordinate relative to window's top edge
    func tap(x: Double, y: Double) -> Bool {
        guard let info = bridge.getWindowInfo() else { return false }

        // Convert window-relative coords to screen-absolute coords
        let screenX = info.position.x + CGFloat(x)
        let screenY = info.position.y + CGFloat(y)
        let point = CGPoint(x: screenX, y: screenY)

        // Activate the window first
        bridge.activate()
        usleep(100_000) // 100ms for activation

        // Mouse down + mouse up = click
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return false }

        guard let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return false }

        mouseDown.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms between down and up
        mouseUp.post(tap: .cghidEventTap)

        return true
    }

    /// Swipe from one point to another relative to the mirroring window.
    /// - Parameters:
    ///   - fromX: Start X coordinate relative to window
    ///   - fromY: Start Y coordinate relative to window
    ///   - toX: End X coordinate relative to window
    ///   - toY: End Y coordinate relative to window
    ///   - durationMs: Duration of the swipe in milliseconds
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int = 300)
        -> Bool
    {
        guard let info = bridge.getWindowInfo() else { return false }

        let startPoint = CGPoint(
            x: info.position.x + CGFloat(fromX),
            y: info.position.y + CGFloat(fromY)
        )
        let endPoint = CGPoint(
            x: info.position.x + CGFloat(toX),
            y: info.position.y + CGFloat(toY)
        )

        bridge.activate()
        usleep(100_000)

        // Mouse down at start
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: startPoint,
            mouseButton: .left
        ) else { return false }
        mouseDown.post(tap: .cghidEventTap)

        // Interpolate drag events over the duration
        let steps = 20
        let stepDelay = UInt32(durationMs * 1000 / steps)
        for i in 1...steps {
            let progress = Double(i) / Double(steps)
            let currentX = startPoint.x + (endPoint.x - startPoint.x) * CGFloat(progress)
            let currentY = startPoint.y + (endPoint.y - startPoint.y) * CGFloat(progress)
            let currentPoint = CGPoint(x: currentX, y: currentY)

            guard let drag = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: currentPoint,
                mouseButton: .left
            ) else { return false }
            drag.post(tap: .cghidEventTap)
            usleep(stepDelay)
        }

        // Mouse up at end
        guard let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: endPoint,
            mouseButton: .left
        ) else { return false }
        mouseUp.post(tap: .cghidEventTap)

        return true
    }

    /// Type text by sending keyboard events.
    /// - Parameter text: The text string to type.
    func typeText(_ text: String) -> Bool {
        bridge.activate()
        usleep(100_000)

        for character in text {
            let str = String(character) as CFString
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { return false }

            // Use Unicode string input instead of virtual key codes
            var unicodeChars = [UniChar]()
            let nsStr = str as NSString
            for i in 0..<nsStr.length {
                unicodeChars.append(nsStr.character(at: i))
            }

            keyDown.keyboardSetUnicodeString(
                stringLength: unicodeChars.count, unicodeString: &unicodeChars
            )
            keyUp.keyboardSetUnicodeString(
                stringLength: unicodeChars.count, unicodeString: &unicodeChars
            )

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(20_000) // 20ms between keystrokes
        }

        return true
    }

    /// Send a special key press (e.g., Return, Escape, Delete).
    func pressKey(_ keyCode: CGKeyCode) -> Bool {
        bridge.activate()
        usleep(100_000)

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return false }

        keyDown.post(tap: .cghidEventTap)
        usleep(50_000)
        keyUp.post(tap: .cghidEventTap)

        return true
    }
}

// MARK: - Common Key Codes

enum KeyCode {
    static let returnKey: CGKeyCode = 36
    static let escape: CGKeyCode = 53
    static let delete: CGKeyCode = 51
    static let space: CGKeyCode = 49
    static let tab: CGKeyCode = 48
}
