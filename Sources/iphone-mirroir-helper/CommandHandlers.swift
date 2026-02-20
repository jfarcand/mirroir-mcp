// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Command handler implementations for the helper daemon's Unix socket protocol.
// ABOUTME: Each handler maps a JSON action (click, type, swipe, etc.) to Karabiner HID operations.

import CoreGraphics
import Foundation
import HelperLib

/// Extract a Double parameter from a JSON dictionary.
private func doubleParam(_ json: [String: Any], _ key: String) -> Double? {
    (json[key] as? NSNumber)?.doubleValue
}

/// Extract an Int parameter from a JSON dictionary.
private func intParam(_ json: [String: Any], _ key: String) -> Int? {
    (json[key] as? NSNumber)?.intValue
}

/// Extract an Int8 parameter from a JSON dictionary.
private func int8Param(_ json: [String: Any], _ key: String) -> Int8? {
    (json[key] as? NSNumber)?.int8Value
}

extension CommandServer {

    // MARK: - Command Dispatch

    /// Parse and execute a JSON command, returning the JSON response.
    func processCommand(data: Data) -> Data {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            logHelper("JSON parse failed: \(error)")
            return makeErrorResponse("Invalid JSON command: \(error.localizedDescription)")
        }
        guard let json = parsed as? [String: Any],
              let action = json["action"] as? String
        else {
            return makeErrorResponse("Invalid JSON command: missing 'action' key")
        }

        switch action {
        case "click":
            return handleClick(json)
        case "long_press":
            return handleLongPress(json)
        case "double_tap":
            return handleDoubleTap(json)
        case "drag":
            return handleDrag(json)
        case "type":
            return handleType(json)
        case "swipe":
            return handleSwipe(json)
        case "move":
            return handleMove(json)
        case "press_key":
            return handlePressKey(json)
        case "shake":
            return handleShake()
        case "status":
            return handleStatus()
        default:
            return makeErrorResponse("Unknown action: \(action)")
        }
    }

    // MARK: - Command Handlers

    /// Click at screen-absolute coordinates.
    /// Disconnects physical mouse, warps to target, sends Karabiner click, restores cursor.
    /// CGAssociateMouseAndMouseCursorPosition(false) prevents the user's physical mouse
    /// from interfering with the programmatic cursor placement during the operation.
    func handleClick(_ json: [String: Any]) -> Data {
        guard let x = doubleParam(json, "x"),
              let y = doubleParam(json, "y")
        else {
            return makeErrorResponse("click requires x and y (numbers)")
        }

        guard karabiner.isPointingReady else {
            return makeErrorResponse("Karabiner pointing device not ready")
        }

        CursorSync.withCursorSynced(at: CGPoint(x: x, y: y), karabiner: karabiner) {
            CursorSync.clickButton(karabiner: karabiner, holdDuration: EnvConfig.clickHoldUs)
        }

        return makeOkResponse()
    }

    /// Long press at screen-absolute coordinates.
    /// Same flow as click, but holds the button down for a configurable duration.
    /// Default hold is 500ms (iOS standard long-press threshold).
    /// Minimum hold is 100ms to avoid confusion with a regular tap.
    func handleLongPress(_ json: [String: Any]) -> Data {
        guard let x = doubleParam(json, "x"),
              let y = doubleParam(json, "y")
        else {
            return makeErrorResponse("long_press requires x and y (numbers)")
        }

        let durationMs = max(intParam(json, "duration_ms") ?? 500, 100)

        guard karabiner.isPointingReady else {
            return makeErrorResponse("Karabiner pointing device not ready")
        }

        CursorSync.withCursorSynced(at: CGPoint(x: x, y: y), karabiner: karabiner) {
            CursorSync.clickButton(karabiner: karabiner, holdDuration: UInt32(durationMs) * 1000)
        }

        return makeOkResponse()
    }

    /// Double-tap at screen-absolute coordinates.
    /// Performs two rapid click cycles with a short inter-tap gap.
    /// Timing: 40ms hold + 50ms gap + 40ms hold = 130ms total,
    /// well within iOS's ~300ms double-tap recognition window.
    func handleDoubleTap(_ json: [String: Any]) -> Data {
        guard let x = doubleParam(json, "x"),
              let y = doubleParam(json, "y")
        else {
            return makeErrorResponse("double_tap requires x and y (numbers)")
        }

        guard karabiner.isPointingReady else {
            return makeErrorResponse("Karabiner pointing device not ready")
        }

        CursorSync.withCursorSynced(at: CGPoint(x: x, y: y), karabiner: karabiner) {
            // First tap
            CursorSync.clickButton(karabiner: karabiner, holdDuration: EnvConfig.doubleTapHoldUs)
            usleep(EnvConfig.doubleTapGapUs)
            // Second tap
            CursorSync.clickButton(karabiner: karabiner, holdDuration: EnvConfig.doubleTapHoldUs)
        }

        return makeOkResponse()
    }

    /// Drag from one screen-absolute point to another with sustained contact.
    /// Unlike swipe (quick flick), drag uses a longer initial hold to trigger iOS
    /// drag recognition (~150ms), then moves slowly with fine interpolation.
    /// Default duration is 1000ms. Minimum is 200ms to distinguish from swipe.
    func handleDrag(_ json: [String: Any]) -> Data {
        guard let fromX = doubleParam(json, "from_x"),
              let fromY = doubleParam(json, "from_y"),
              let toX = doubleParam(json, "to_x"),
              let toY = doubleParam(json, "to_y")
        else {
            return makeErrorResponse("drag requires from_x, from_y, to_x, to_y (numbers)")
        }

        let durationMs = max(intParam(json, "duration_ms") ?? 1000, 200)

        guard karabiner.isPointingReady else {
            return makeErrorResponse("Karabiner pointing device not ready")
        }

        CursorSync.withCursorSynced(at: CGPoint(x: fromX, y: fromY), karabiner: karabiner) {
            // Button down with initial hold for iOS drag recognition
            var down = PointingInput()
            down.buttons = 0x01
            karabiner.postPointingReport(down)
            usleep(EnvConfig.dragModeHoldUs)

            // Slow interpolated movement with fine steps
            let steps = EnvConfig.dragInterpolationSteps
            let totalDx = toX - fromX
            let totalDy = toY - fromY
            let dragModeHoldMs = Int(EnvConfig.dragModeHoldUs / 1000)
            let moveDurationMs = durationMs - dragModeHoldMs
            let stepDelayUs = UInt32(max(moveDurationMs, 1) * 1000 / steps)

            for i in 1...steps {
                let progress = Double(i) / Double(steps)
                let targetX = fromX + totalDx * progress
                let targetY = fromY + totalDy * progress

                CGWarpMouseCursorPosition(CGPoint(x: targetX, y: targetY))

                let dx = Int8(clamping: Int(totalDx / Double(steps)))
                let dy = Int8(clamping: Int(totalDy / Double(steps)))
                var move = PointingInput()
                move.buttons = 0x01
                move.x = dx
                move.y = dy
                karabiner.postPointingReport(move)
                usleep(stepDelayUs)
            }

            // Button up
            var up = PointingInput()
            up.buttons = 0x00
            karabiner.postPointingReport(up)
            usleep(EnvConfig.cursorSettleUs)
        }

        return makeOkResponse()
    }

    /// Type text by mapping each character to HID keycodes.
    /// Characters without a US QWERTY HID mapping are skipped and reported in the response.
    ///
    /// When `focus_x`/`focus_y` are provided, clicks those screen-absolute coordinates
    /// first to give the target window keyboard focus. This happens atomically within
    /// the same command — no IPC round-trip gap where another window could steal focus.
    func handleType(_ json: [String: Any]) -> Data {
        guard let text = json["text"] as? String, !text.isEmpty else {
            return makeErrorResponse("type requires non-empty text (string)")
        }

        guard karabiner.isKeyboardReady else {
            return makeErrorResponse("Karabiner keyboard device not ready")
        }

        // Atomic focus: click the title bar to give the window keyboard focus,
        // keep the cursor parked there with physical mouse disconnected during
        // the entire typing operation. Only restore cursor after all typing is done.
        var savedPosition: CGPoint = .zero
        let hasFocusClick: Bool
        if let focusX = doubleParam(json, "focus_x"),
           let focusY = doubleParam(json, "focus_y"),
           karabiner.isPointingReady {
            hasFocusClick = true
            let target = CGPoint(x: focusX, y: focusY)
            savedPosition = CGEvent(source: nil)?.location ?? .zero
            logHelper("handleType: focus click at (\(focusX), \(focusY)), cursor saved at (\(Int(savedPosition.x)), \(Int(savedPosition.y)))")

            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
            CGWarpMouseCursorPosition(target)
            usleep(EnvConfig.cursorSettleUs)

            CursorSync.nudgeSync(karabiner: karabiner)
            CursorSync.clickButton(karabiner: karabiner, holdDuration: EnvConfig.clickHoldUs)

            usleep(EnvConfig.focusSettleUs)
            // Cursor stays on target, physical mouse stays disconnected
        } else {
            hasFocusClick = false
            logHelper("handleType: no focus click (focus_x=\(String(describing: json["focus_x"])), focus_y=\(String(describing: json["focus_y"])), pointing=\(karabiner.isPointingReady))")
        }

        var skippedChars = [String]()

        for char in text {
            guard let sequence = HIDKeyMap.lookupSequence(char) else {
                let codepoint = char.unicodeScalars.first.map { "U+\(String($0.value, radix: 16, uppercase: true))" } ?? "?"
                logHelper("No HID mapping for character: '\(char)' (\(codepoint))")
                skippedChars.append(String(char))
                continue
            }

            let isDeadKey = sequence.steps.count > 1
            for (stepIndex, step) in sequence.steps.enumerated() {
                if stepIndex > 0 {
                    // Delay between dead-key trigger and base character
                    usleep(EnvConfig.deadKeyDelayUs)
                }
                karabiner.typeKey(keycode: step.keycode, modifiers: step.modifiers)
            }
            // Dead-key sequences need extra settle time for iOS to clear compose
            // state and release the Option modifier before the next character.
            usleep(isDeadKey ? EnvConfig.deadKeyDelayUs : EnvConfig.keystrokeDelayUs)
        }

        // Restore cursor and reconnect physical mouse after all typing is done
        if hasFocusClick {
            CGWarpMouseCursorPosition(savedPosition)
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        }

        if skippedChars.isEmpty {
            return makeOkResponse()
        }
        return safeJSON([
            "ok": true,
            "skipped_characters": skippedChars.joined(),
            "warning": "Some characters have no US QWERTY HID mapping and were not typed",
        ])
    }

    /// Swipe from one screen-absolute point to another using scroll wheel events.
    /// iPhone Mirroring maps mouse scroll to iOS swipe/scroll gestures, while
    /// click-drag maps to touch-and-drag (icon rearranging). Scroll wheel is
    /// the correct input for page changes, list scrolling, and content swiping.
    func handleSwipe(_ json: [String: Any]) -> Data {
        guard let fromX = doubleParam(json, "from_x"),
              let fromY = doubleParam(json, "from_y"),
              let toX = doubleParam(json, "to_x"),
              let toY = doubleParam(json, "to_y")
        else {
            return makeErrorResponse("swipe requires from_x, from_y, to_x, to_y (numbers)")
        }

        let durationMs = intParam(json, "duration_ms") ?? 300

        guard karabiner.isPointingReady else {
            return makeErrorResponse("Karabiner pointing device not ready")
        }

        // Warp cursor to the midpoint of the swipe so scroll events target
        // the correct area of the iPhone Mirroring window
        let midX = (fromX + toX) / 2.0
        let midY = (fromY + toY) / 2.0

        CursorSync.withCursorSynced(at: CGPoint(x: midX, y: midY), karabiner: karabiner) {
            // Send scroll wheel events to simulate the swipe gesture.
            // No button press — scroll wheel maps to iOS swipe/scroll, while
            // click-drag maps to touch-and-drag (which triggers icon jiggle mode).
            let totalDx = toX - fromX
            let totalDy = toY - fromY
            let steps = EnvConfig.swipeInterpolationSteps
            let stepDelayUs = UInt32(max(durationMs, 1) * 1000 / steps)

            // Scale pixel distance to scroll wheel units. Scroll wheel values are
            // much coarser than pixels — each unit scrolls several pixels.
            // Using a divisor to convert pixel distance to reasonable scroll ticks.
            let scrollScale = EnvConfig.scrollPixelScale
            var hAccum = 0.0
            var vAccum = 0.0
            let hPerStep = totalDx / scrollScale / Double(steps)
            let vPerStep = totalDy / scrollScale / Double(steps)

            for _ in 1...steps {
                hAccum += hPerStep
                vAccum += vPerStep

                let hTick = Int8(clamping: Int(hAccum.rounded()))
                let vTick = Int8(clamping: Int(vAccum.rounded()))

                hAccum -= Double(hTick)
                vAccum -= Double(vTick)

                var scroll = PointingInput()
                // Negate: scroll wheel convention is opposite to swipe direction
                scroll.horizontalWheel = -hTick
                scroll.verticalWheel = -vTick
                karabiner.postPointingReport(scroll)
                usleep(stepDelayUs)
            }
        }

        return makeOkResponse()
    }

    /// Send relative mouse movement.
    func handleMove(_ json: [String: Any]) -> Data {
        guard let dx = int8Param(json, "dx"),
              let dy = int8Param(json, "dy")
        else {
            return makeErrorResponse("move requires dx and dy (integers)")
        }

        guard karabiner.isPointingReady else {
            return makeErrorResponse("Karabiner pointing device not ready")
        }

        karabiner.moveMouse(dx: dx, dy: dy)
        return makeOkResponse()
    }

    /// Press a key with optional modifiers.
    /// Supports special keys (return, escape, arrows, etc.) via `HIDSpecialKeyMap`,
    /// and single printable characters (a-z, 0-9, etc.) via `HIDKeyMap`.
    /// This enables shortcuts like Cmd+A, Cmd+L, Cmd+C.
    func handlePressKey(_ json: [String: Any]) -> Data {
        guard let keyName = json["key"] as? String else {
            return makeErrorResponse("press_key requires key (string)")
        }

        guard karabiner.isKeyboardReady else {
            return makeErrorResponse("Karabiner keyboard device not ready")
        }

        let modifierNames = json["modifiers"] as? [String] ?? []
        var modifiers = HIDSpecialKeyMap.modifiers(from: modifierNames)

        // Try special key names first, then fall back to single printable characters
        let hidKeyCode: UInt16
        if let specialCode = HIDSpecialKeyMap.hidKeyCode(for: keyName) {
            hidKeyCode = specialCode
        } else if keyName.count == 1, let char = keyName.first,
                  let mapping = HIDKeyMap.lookup(char) {
            hidKeyCode = mapping.keycode
            // Merge any modifiers the character itself requires (e.g., shift for uppercase)
            modifiers.insert(mapping.modifiers)
        } else {
            let supported = HIDSpecialKeyMap.supportedKeys.joined(separator: ", ")
            return makeErrorResponse(
                "Unknown key: \"\(keyName)\". Supported: \(supported), or a single character (a-z, 0-9, etc.)")
        }

        karabiner.typeKey(keycode: hidKeyCode, modifiers: modifiers)
        return makeOkResponse()
    }

    /// Trigger a shake gesture by sending Ctrl+Cmd+Z via the virtual keyboard.
    /// This key combination triggers shake-to-undo in iOS apps and opens debug
    /// menus in development tools like Expo Go and React Native.
    func handleShake() -> Data {
        guard karabiner.isKeyboardReady else {
            return makeErrorResponse("Karabiner keyboard device not ready")
        }

        // HID keycode 0x1D = 'z' key (USB HID Usage Page 0x07)
        let zKeycode: UInt16 = 0x1D
        let modifiers: KeyboardModifier = [.leftControl, .leftCommand]
        karabiner.typeKey(keycode: zKeycode, modifiers: modifiers)
        return makeOkResponse()
    }

    /// Return current device readiness status.
    func handleStatus() -> Data {
        let status: [String: Any] = [
            "ok": karabiner.isConnected,
            "keyboard_ready": karabiner.isKeyboardReady,
            "pointing_ready": karabiner.isPointingReady,
        ]
        return safeJSON(status)
    }
}
