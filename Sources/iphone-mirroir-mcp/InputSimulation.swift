// ABOUTME: Simulates user input (tap, swipe, keyboard) on the iPhone Mirroring window.
// ABOUTME: Delegates to the privileged Karabiner helper for DRM-protected input, falls back to CGEvent.

import CoreGraphics
import Foundation

/// Simulates touch and keyboard input on the iPhone Mirroring window.
/// All coordinates are relative to the mirroring window's content area.
///
/// Uses the Karabiner helper daemon for input delivery when available.
/// The helper uses virtual HID devices to bypass the DRM-protected surface.
/// Falls back to CGEvent-based input when the helper is not running.
final class InputSimulation: @unchecked Sendable {
    private let bridge: MirroringBridge
    let helperClient = HelperClient()

    /// Reusable event source for CGEvent fallback path.
    /// Uses HID system state with suppression tuning so synthetic events
    /// are not filtered by the DRM-protected mirroring surface.
    private let eventSource: CGEventSource?

    init(bridge: MirroringBridge) {
        self.bridge = bridge

        let source = CGEventSource(stateID: .hidSystemState)
        if let source {
            source.localEventsSuppressionInterval = 0.0
            source.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitLocalKeyboardEvents,
                 .permitSystemDefinedEvents],
                state: .eventSuppressionStateSuppressionInterval
            )
        }
        self.eventSource = source
    }

    /// Tap at a position relative to the mirroring window.
    /// Delegates to Karabiner helper when available, falls back to CGEvent.
    func tap(x: Double, y: Double) -> Bool {
        guard let info = bridge.getWindowInfo() else { return false }

        // Convert window-relative coords to screen-absolute coords
        let screenX = info.position.x + CGFloat(x)
        let screenY = info.position.y + CGFloat(y)

        // Activate the window before any input
        activateWindow()
        usleep(200_000) // 200ms for activation

        // Try Karabiner helper first (works on DRM-protected surface)
        if helperClient.click(x: Double(screenX), y: Double(screenY)) {
            return true
        }

        // Fallback: CGEvent-based input
        return tapViaCGEvent(screenX: screenX, screenY: screenY)
    }

    /// Swipe from one point to another relative to the mirroring window.
    /// Delegates to Karabiner helper when available, falls back to CGEvent.
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int = 300)
        -> Bool
    {
        guard let info = bridge.getWindowInfo() else { return false }

        let startX = Double(info.position.x) + fromX
        let startY = Double(info.position.y) + fromY
        let endX = Double(info.position.x) + toX
        let endY = Double(info.position.y) + toY

        activateWindow()
        usleep(200_000) // 200ms for activation

        // Try Karabiner helper first
        if helperClient.swipe(fromX: startX, fromY: startY,
                              toX: endX, toY: endY,
                              durationMs: durationMs) {
            return true
        }

        // Fallback: CGEvent-based swipe
        return swipeViaCGEvent(
            startX: CGFloat(startX), startY: CGFloat(startY),
            endX: CGFloat(endX), endY: CGFloat(endY),
            durationMs: durationMs
        )
    }

    /// Type text by sending keyboard events.
    /// Delegates to Karabiner helper when available, falls back to CGEvent.
    func typeText(_ text: String) -> Bool {
        bridge.activate()
        usleep(100_000)

        // Try Karabiner helper first
        if helperClient.type(text: text) {
            return true
        }

        // Fallback: CGEvent Unicode input
        return typeViaCGEvent(text)
    }

    /// Send a special key press (e.g., Return, Escape, Delete).
    func pressKey(_ keyCode: CGKeyCode) -> Bool {
        bridge.activate()
        usleep(100_000)

        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        else { return false }

        keyDown.post(tap: .cghidEventTap)
        usleep(50_000)
        keyUp.post(tap: .cghidEventTap)

        return true
    }

    // MARK: - CGEvent Fallback Implementations

    private func tapViaCGEvent(screenX: CGFloat, screenY: CGFloat) -> Bool {
        let point = CGPoint(x: screenX, y: screenY)

        CGWarpMouseCursorPosition(point)
        usleep(50_000)

        guard let moveEvent = createMouseEvent(type: .mouseMoved, point: point) else {
            return false
        }
        moveEvent.post(tap: .cghidEventTap)
        usleep(50_000)

        guard let mouseDown = createMouseEvent(type: .leftMouseDown, point: point) else {
            return false
        }
        mouseDown.post(tap: .cghidEventTap)
        usleep(50_000)

        guard let mouseUp = createMouseEvent(type: .leftMouseUp, point: point) else {
            return false
        }
        mouseUp.post(tap: .cghidEventTap)

        return true
    }

    private func swipeViaCGEvent(
        startX: CGFloat, startY: CGFloat,
        endX: CGFloat, endY: CGFloat,
        durationMs: Int
    ) -> Bool {
        let startPoint = CGPoint(x: startX, y: startY)
        let endPoint = CGPoint(x: endX, y: endY)

        CGWarpMouseCursorPosition(startPoint)
        usleep(50_000)

        guard let mouseDown = createMouseEvent(type: .leftMouseDown, point: startPoint) else {
            return false
        }
        mouseDown.post(tap: .cghidEventTap)
        usleep(30_000)

        let steps = 40
        let stepDelay = UInt32(durationMs * 1000 / steps)
        for i in 1...steps {
            let progress = Double(i) / Double(steps)
            let currentX = startPoint.x + (endPoint.x - startPoint.x) * CGFloat(progress)
            let currentY = startPoint.y + (endPoint.y - startPoint.y) * CGFloat(progress)
            let currentPoint = CGPoint(x: currentX, y: currentY)

            CGWarpMouseCursorPosition(currentPoint)

            guard let drag = createMouseEvent(type: .leftMouseDragged, point: currentPoint) else {
                return false
            }
            drag.post(tap: .cghidEventTap)
            usleep(stepDelay)
        }

        guard let mouseUp = createMouseEvent(type: .leftMouseUp, point: endPoint) else {
            return false
        }
        mouseUp.post(tap: .cghidEventTap)

        return true
    }

    private func typeViaCGEvent(_ text: String) -> Bool {
        for character in text {
            let str = String(character) as CFString
            guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
            else { return false }

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
            usleep(20_000)
        }
        return true
    }

    // MARK: - Private Helpers

    /// Create a mouse event with proper source and full pressure.
    private func createMouseEvent(type: CGEventType, point: CGPoint) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return nil }

        // Set maximum pressure (255) — iPhone Mirroring maps mouse pressure to touch.
        event.setIntegerValueField(.mouseEventPressure, value: 255)

        return event
    }

    /// Activate the iPhone Mirroring window using multiple strategies.
    private func activateWindow() {
        bridge.activate()

        let script = """
            tell application "iPhone Mirroring" to activate
            """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
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
