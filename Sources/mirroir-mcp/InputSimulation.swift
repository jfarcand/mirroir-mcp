// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Simulates user input (tap, swipe, keyboard) on the iPhone Mirroring window.
// ABOUTME: Uses CGEvent for all input — pointing (tap, swipe, drag) and keyboard (type, press_key, shake).

import AppKit
import Carbon
import CoreGraphics
import Foundation
import HelperLib

/// Result of a type or key press operation.
struct TypeResult {
    let success: Bool
    let warning: String?
    let error: String?
}

/// Controls how the mouse cursor is managed during coordinate-based operations.
/// Pluggable: new strategies can be added as enum cases.
enum CursorMode: Sendable {
    /// No cursor management — cursor moves to the target and stays there.
    /// Used for iPhone Mirroring where HID events are consumed by the
    /// mirroring session without affecting the user's workflow.
    case direct

    /// Save the cursor position before the operation, restore it after.
    /// Used for generic window targets where automation shares the macOS
    /// cursor with the user.
    case preserving
}

/// Simulates touch and keyboard input on a target window.
/// All coordinates are relative to the target window's content area.
///
/// All operations use CGEvent posted directly into the macOS event pipeline.
/// Pointing operations (tap, swipe, drag, long press, double tap) use mouse events.
/// Keyboard operations (type, press_key, shake) use keyboard events.
final class InputSimulation: Sendable {
    private let bridge: any WindowBridging
    private let mirroringBundleID: String
    private let cursorMode: CursorMode
    /// Character substitution table for translating between the iPhone's hardware
    /// keyboard layout and US QWERTY. Built once at init from the first non-US
    /// keyboard layout found on the Mac. CGEvent keycodes are physical keys
    /// (layout-independent), same as HID — substitution is still needed.
    private let layoutSubstitution: [Character: Character]
    /// When non-nil, mouse events are posted directly to this PID without
    /// moving the system cursor. Only works for regular macOS apps, not
    /// iPhone Mirroring. Resolved at init from MIRROIR_CURSOR_FREE env var.
    private let cursorFreePID: pid_t?

    init(bridge: any WindowBridging, cursorMode: CursorMode = .direct,
         layoutSubstitution override: [Character: Character]? = nil) {
        self.bridge = bridge
        self.cursorMode = cursorMode
        if EnvConfig.cursorFreeInput, let app = bridge.findProcess() {
            self.cursorFreePID = app.processIdentifier
        } else {
            self.cursorFreePID = nil
        }
        // Resolve the process name for AppleScript focus management.
        // iPhone Mirroring uses the configured process name; generic targets
        // fall back to the process name from the running application.
        if let menuBridge = bridge as? MirroringBridge {
            self.mirroringBundleID = menuBridge.targetName == "iphone"
                ? EnvConfig.mirroringBundleID
                : bridge.findProcess()?.bundleIdentifier ?? EnvConfig.mirroringBundleID
        } else {
            self.mirroringBundleID = bridge.findProcess()?.bundleIdentifier ?? ""
        }

        // Build layout substitution table when the iPhone's hardware keyboard
        // layout differs from US QWERTY. Option-modified keycodes go through
        // the iPhone's configured layout, so dead-key sequences (é, è, ç, etc.)
        // produce wrong characters without substitution.
        if let explicitSubstitution = override {
            self.layoutSubstitution = explicitSubstitution
        } else if let usData = LayoutMapper.layoutData(forSourceID: "com.apple.keylayout.US"),
           let (targetID, targetData) = LayoutMapper.findNonUSLayout()
        {
            self.layoutSubstitution = LayoutMapper.buildSubstitution(
                usLayoutData: usData, targetLayoutData: targetData
            )
            if !self.layoutSubstitution.isEmpty {
                fputs("LayoutMapper: \(self.layoutSubstitution.count) character substitutions for \(targetID)\n", stderr)
            }
        } else {
            self.layoutSubstitution = [:]
        }
    }

    /// Verify that the target window is connected and accepting input.
    /// Returns a state-specific error message if input should be blocked, nil if safe to proceed.
    private func checkMirroringConnected(tag: String) -> String? {
        let state = bridge.getState()
        switch state {
        case .connected:
            return nil
        case .paused:
            DebugLog.log(tag, "ERROR: target paused")
            return "Target '\(bridge.targetName)' is paused. Unlock iPhone or click Resume in the mirroring window."
        case .noWindow:
            DebugLog.log(tag, "ERROR: no window")
            return "Target '\(bridge.targetName)' window not found. Is the app running?"
        case .notRunning:
            DebugLog.log(tag, "ERROR: not running")
            return "Target '\(bridge.targetName)' is not running. Launch iPhone Mirroring first."
        }
    }

    /// Common preamble for pointing operations (tap, swipe, drag, long press, double tap).
    /// Validates that the target is connected, the window exists, and coordinates are in bounds.
    /// All pointing operations use CGEvent — no external dependencies.
    /// Returns `(info, focusChanged, nil)` on success, or `(nil, false, errorMessage)` on failure.
    private func preparePointingInput(tag: String, x: Double, y: Double) -> (info: WindowInfo?, focusChanged: Bool, error: String?) {
        if let stateError = checkMirroringConnected(tag: tag) {
            return (nil, false, stateError)
        }

        guard let info = bridge.getWindowInfo() else {
            DebugLog.log(tag, "ERROR: window not found")
            return (nil, false, "Target '\(bridge.targetName)' window not found")
        }

        if let boundsError = validateBounds(x: x, y: y, info: info, tag: tag) {
            return (nil, false, boundsError)
        }

        logWindowState(tag, info)
        let changed = ensureTargetFrontmost()
        return (info, changed, nil)
    }

    /// Common preamble for keyboard operations (type, press_key, shake).
    /// Validates that the target is connected and ensures it's frontmost.
    private func prepareKeyboardInput(tag: String) -> String? {
        if let stateError = checkMirroringConnected(tag: tag) {
            return stateError
        }
        return nil
    }

    // MARK: - Cursor management

    /// Save the current cursor position if the effective cursor mode requires it.
    /// Per-call override takes precedence over the instance default.
    private func saveCursor(mode: CursorMode? = nil) -> CGPoint? {
        guard (mode ?? cursorMode) == .preserving else { return nil }
        return CGEvent(source: nil)?.location
    }

    /// Restore the cursor to a previously saved position.
    private func restoreCursor(_ savedPosition: CGPoint?) {
        guard let pos = savedPosition else { return }
        CGWarpMouseCursorPosition(pos)
    }

    /// Validate that coordinates fall within the iPhone Mirroring window bounds.
    /// Returns nil if valid, or a descriptive error message if out of bounds.
    func validateBounds(x: Double, y: Double, info: WindowInfo, tag: String) -> String? {
        let w = Double(info.size.width)
        let h = Double(info.size.height)
        if x < 0 || x > w || y < 0 || y > h {
            let msg = "Coordinates (\(Int(x)), \(Int(y))) are outside the '\(bridge.targetName)' window (\(Int(w))x\(Int(h))). x must be 0-\(Int(w)), y must be 0-\(Int(h))."
            DebugLog.log(tag, "REJECTED: \(msg)")
            return msg
        }
        return nil
    }

    /// Log window info and frontmost app state for any coordinate-based operation.
    private func logWindowState(_ tag: String, _ info: WindowInfo) {
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        DebugLog.log(tag, "window=(\(Int(info.position.x)),\(Int(info.position.y))) size=\(Int(info.size.width))x\(Int(info.size.height)) frontApp=\(frontApp)")
    }

    /// Tap at a position relative to the target window.
    /// Returns nil on success, or an error message on failure.
    func tap(x: Double, y: Double, cursorMode override: CursorMode? = nil) -> String? {
        let prep = preparePointingInput(tag: "tap", x: x, y: y)
        guard let info = prep.info else { return prep.error ?? "Unknown error" }

        let saved = saveCursor(mode: override)
        defer { restoreCursor(saved) }

        let screenX = info.position.x + CGFloat(x)
        let screenY = info.position.y + CGFloat(y)
        DebugLog.log("tap", "relative=(\(x),\(y)) screen=(\(Int(screenX)),\(Int(screenY)))")

        let result = CGEventInput.click(at: CGPoint(x: screenX, y: screenY), targetPID: cursorFreePID)
        DebugLog.log("tap", "CGEvent=\(result ? "OK" : "FAILED")")
        return result ? nil : "CGEvent click failed"
    }

    /// Swipe from one point to another relative to the target window.
    /// Returns nil on success, or an error message on failure.
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int = 300, cursorMode override: CursorMode? = nil) -> String?
    {
        let prep = preparePointingInput(tag: "swipe", x: fromX, y: fromY)
        guard let info = prep.info else { return prep.error ?? "Unknown error" }

        if let boundsError = validateBounds(x: toX, y: toY, info: info, tag: "swipe") {
            return boundsError
        }

        // After a macOS Space switch, the window is "frontmost" but not
        // the key window for scroll input. A click promotes it to key
        // window. Click the iOS status bar area (top of screen) which
        // in most apps harmlessly scrolls to top.
        if prep.focusChanged {
            let statusBarY = Double(info.position.y) + EnvConfig.statusBarTapY
            let centerScreenX = Double(info.position.x) + Double(info.size.width) / 2.0
            DebugLog.log("swipe", "focus changed — clicking status bar to engage key window")
            _ = CGEventInput.click(at: CGPoint(x: centerScreenX, y: statusBarY), targetPID: cursorFreePID)
            usleep(EnvConfig.spaceSwitchSettleUs)
        }

        let saved = saveCursor(mode: override)
        defer { restoreCursor(saved) }

        let startX = Double(info.position.x) + fromX
        let startY = Double(info.position.y) + fromY
        let endX = Double(info.position.x) + toX
        let endY = Double(info.position.y) + toY

        DebugLog.log("swipe", "from=(\(fromX),\(fromY))->(\(toX),\(toY)) screen=(\(Int(startX)),\(Int(startY)))->(\(Int(endX)),\(Int(endY))) duration=\(durationMs)ms")

        let result = CGEventInput.swipe(
            from: CGPoint(x: startX, y: startY),
            to: CGPoint(x: endX, y: endY),
            durationMs: durationMs,
            targetPID: cursorFreePID
        )
        DebugLog.log("swipe", "CGEvent=\(result ? "OK" : "FAILED")")
        return result ? nil : "CGEvent swipe failed"
    }

    /// Long press at a position relative to the target window.
    /// Returns nil on success, or an error message on failure.
    func longPress(x: Double, y: Double, durationMs: Int = 500,
                   cursorMode override: CursorMode? = nil) -> String? {
        let prep = preparePointingInput(tag: "longPress", x: x, y: y)
        guard let info = prep.info else { return prep.error ?? "Unknown error" }

        let saved = saveCursor(mode: override)
        defer { restoreCursor(saved) }

        let screenX = Double(info.position.x) + x
        let screenY = Double(info.position.y) + y
        DebugLog.log("longPress", "relative=(\(x),\(y)) screen=(\(Int(screenX)),\(Int(screenY))) duration=\(durationMs)ms")

        let result = CGEventInput.longPress(at: CGPoint(x: screenX, y: screenY), durationMs: durationMs, targetPID: cursorFreePID)
        DebugLog.log("longPress", "CGEvent=\(result ? "OK" : "FAILED")")
        return result ? nil : "CGEvent long press failed"
    }

    /// Double-tap at a position relative to the target window.
    /// Returns nil on success, or an error message on failure.
    func doubleTap(x: Double, y: Double, cursorMode override: CursorMode? = nil) -> String? {
        let prep = preparePointingInput(tag: "doubleTap", x: x, y: y)
        guard let info = prep.info else { return prep.error ?? "Unknown error" }

        let saved = saveCursor(mode: override)
        defer { restoreCursor(saved) }

        let screenX = Double(info.position.x) + x
        let screenY = Double(info.position.y) + y
        DebugLog.log("doubleTap", "relative=(\(x),\(y)) screen=(\(Int(screenX)),\(Int(screenY)))")

        let result = CGEventInput.doubleTap(at: CGPoint(x: screenX, y: screenY), targetPID: cursorFreePID)
        DebugLog.log("doubleTap", "CGEvent=\(result ? "OK" : "FAILED")")
        return result ? nil : "CGEvent double tap failed"
    }

    /// Drag from one point to another relative to the target window.
    /// Unlike swipe (quick flick), drag maintains sustained contact for
    /// rearranging icons, adjusting sliders, and drag-and-drop operations.
    /// Returns nil on success, or an error message on failure.
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int = 1000, cursorMode override: CursorMode? = nil) -> String? {
        let prep = preparePointingInput(tag: "drag", x: fromX, y: fromY)
        guard let info = prep.info else { return prep.error ?? "Unknown error" }

        if let boundsError = validateBounds(x: toX, y: toY, info: info, tag: "drag") {
            return boundsError
        }

        let saved = saveCursor(mode: override)
        defer { restoreCursor(saved) }

        let startX = Double(info.position.x) + fromX
        let startY = Double(info.position.y) + fromY
        let endX = Double(info.position.x) + toX
        let endY = Double(info.position.y) + toY

        DebugLog.log("drag", "from=(\(fromX),\(fromY))->(\(toX),\(toY)) screen=(\(Int(startX)),\(Int(startY)))->(\(Int(endX)),\(Int(endY))) duration=\(durationMs)ms")

        let result = CGEventInput.drag(
            from: CGPoint(x: startX, y: startY),
            to: CGPoint(x: endX, y: endY),
            durationMs: durationMs,
            targetPID: cursorFreePID
        )
        DebugLog.log("drag", "CGEvent=\(result ? "OK" : "FAILED")")
        return result ? nil : "CGEvent drag failed"
    }

    /// Trigger a shake gesture on the mirrored iPhone.
    /// Sends Ctrl+Cmd+Z via CGEvent which triggers shake-to-undo in iOS apps.
    func shake() -> TypeResult {
        if let keyboardError = prepareKeyboardInput(tag: "shake") {
            return TypeResult(success: false, warning: nil, error: keyboardError)
        }

        DebugLog.log("shake", "sending shake gesture via CGEvent")
        ensureTargetFrontmost()

        let result = CGEventInput.shake()
        DebugLog.log("shake", "CGEvent=\(result ? "OK" : "FAILED")")
        if result {
            return TypeResult(success: true, warning: nil, error: nil)
        }
        return TypeResult(success: false, warning: nil, error: "CGEvent shake failed")
    }

    /// Launch an app by name using Spotlight search.
    /// Opens Spotlight, types the app name, waits for results, and presses Return.
    /// Returns nil on success, or an error message on failure.
    func launchApp(name: String) -> String? {
        if let stateError = checkMirroringConnected(tag: "launchApp") {
            return stateError
        }
        DebugLog.log("launchApp", "launching '\(name)'")

        // Step 1: Open Spotlight via menu action (requires MenuActionCapable)
        guard let menuBridge = bridge as? (any MenuActionCapable),
              menuBridge.triggerMenuAction(menu: "View", item: "Spotlight") else {
            DebugLog.log("launchApp", "ERROR: failed to open Spotlight")
            return "Failed to open Spotlight. Is target '\(bridge.targetName)' running?"
        }
        usleep(EnvConfig.spotlightAppearanceUs)

        // Step 2: Type the app name
        let typeResult = typeText(name)
        guard typeResult.success else {
            DebugLog.log("launchApp", "ERROR: failed to type app name")
            return typeResult.error ?? "Failed to type app name"
        }
        usleep(EnvConfig.searchResultsPopulateUs)

        // Step 3: Press Return to launch the top result
        let keyResult = pressKey(keyName: "return")
        guard keyResult.success else {
            DebugLog.log("launchApp", "ERROR: failed to press Return")
            return keyResult.error ?? "Failed to press Return"
        }

        DebugLog.log("launchApp", "launched '\(name)' OK")
        return nil
    }

    /// Open a URL on the mirrored iPhone by launching Safari and navigating to it.
    /// Opens Safari via Spotlight, selects the address bar with Cmd+L, types the URL,
    /// and presses Return to navigate.
    /// Returns nil on success, or an error message on failure.
    func openURL(_ url: String) -> String? {
        DebugLog.log("openURL", "opening '\(url)'")

        // Step 1: Launch Safari
        if let error = launchApp(name: "Safari") {
            return error
        }
        usleep(EnvConfig.safariLoadUs)

        // Step 2: Select the address bar with Cmd+L (works whether Safari was
        // already open or just launched, and clears any existing URL)
        let selectResult = pressKey(keyName: "l", modifiers: ["command"])
        guard selectResult.success else {
            return selectResult.error ?? "Failed to select address bar"
        }
        usleep(EnvConfig.addressBarActivateUs)

        // Step 3: Type the URL
        let typeResult = typeText(url)
        guard typeResult.success else {
            return typeResult.error ?? "Failed to type URL"
        }
        usleep(EnvConfig.preReturnUs)

        // Step 4: Press Return to navigate
        let goResult = pressKey(keyName: "return")
        guard goResult.success else {
            return goResult.error ?? "Failed to press Return"
        }

        return nil
    }

    /// Ensure the target window is the frontmost app so it receives input.
    /// Always activates because NSWorkspace.frontmostApplication can report
    /// stale values when another app gained focus between MCP calls.
    /// Only sleeps for Space-switch settling when we weren't already frontmost.
    ///
    /// Uses AppleScript `set frontmost to true` via System Events for
    /// cross-Space activation (NSRunningApplication.activate() cannot trigger
    /// a macOS Space switch, deprecated in macOS 14).
    ///
    /// - Returns: `true` if the window was not already frontmost (focus changed).
    @discardableResult
    private func ensureTargetFrontmost() -> Bool {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let alreadyFront = frontApp?.bundleIdentifier == mirroringBundleID

        if alreadyFront {
            DebugLog.log("focus", "likely frontmost, re-confirming")
        } else {
            DebugLog.log("focus", "switching from \(frontApp?.bundleIdentifier ?? "nil")")
        }

        // Resolve the process name for the current target's running application.
        // For iPhone Mirroring this is the configured process name; for generic
        // targets it's the app's localized name from NSRunningApplication.
        let processName: String
        if bridge is MirroringBridge {
            processName = EnvConfig.mirroringProcessName
        } else if let app = bridge.findProcess(), let name = app.localizedName {
            processName = name
        } else {
            // Fallback: use NSRunningApplication.activate() directly
            bridge.activate()
            if !alreadyFront { usleep(EnvConfig.spaceSwitchSettleUs) }
            return !alreadyFront
        }

        let script = NSAppleScript(source: """
            tell application "System Events"
                tell process "\(processName)"
                    set frontmost to true
                end tell
            end tell
            """)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        if let err = errorInfo {
            DebugLog.log("focus", "AppleScript error: \(err)")
        }

        if !alreadyFront {
            usleep(EnvConfig.spaceSwitchSettleUs)
        }

        let afterApp = NSWorkspace.shared.frontmostApplication
        DebugLog.log("focus", "after activation frontApp=\(afterApp?.bundleIdentifier ?? "nil")")
        return !alreadyFront
    }

    /// Type text via CGEvent keyboard events.
    ///
    /// CGEvent keycodes are layout-independent physical keys (same concept as
    /// USB HID keycodes). When `IPHONE_KEYBOARD_LAYOUT` is set to a non-US
    /// layout, characters are translated through a layout substitution table
    /// before mapping to keycodes. Characters with no CGKeyMap mapping are
    /// skipped and reported in the warning field of the result.
    func typeText(_ text: String) -> TypeResult {
        if let keyboardError = prepareKeyboardInput(tag: "typeText") {
            return TypeResult(success: false, warning: nil, error: keyboardError)
        }

        DebugLog.log("typeText", "typing \(text.count) char(s)")
        ensureTargetFrontmost()

        // Split text into segments: typeable (substituted) vs skip (no mapping).
        let segments = buildTypeSegments(text)
        var skippedChars = ""

        for segment in segments {
            switch segment.method {
            case .keyEvent:
                if let error = typeViaCGEvent(segment.text) {
                    return error
                }
            case .skip:
                // No working paste mechanism — collect skipped characters for the warning
                skippedChars += segment.text
                fputs("InputSimulation: skipping \(segment.text.count) char(s) with no key mapping\n", stderr)
            }
        }

        if !skippedChars.isEmpty {
            return TypeResult(
                success: true,
                warning: "Skipped \(skippedChars.count) character(s) with no key mapping",
                error: nil
            )
        }
        return TypeResult(success: true, warning: nil, error: nil)
    }

    /// A segment of text to be typed, with the method to use.
    enum TypeMethod { case keyEvent, skip }
    struct TypeSegment {
        let text: String
        let method: TypeMethod
    }

    /// Split text into segments based on whether each character can be typed
    /// via CGEvent key events (after layout substitution) or must be skipped.
    func buildTypeSegments(_ text: String) -> [TypeSegment] {
        var segments: [TypeSegment] = []
        var currentText = ""
        var currentMethod: TypeMethod = .keyEvent

        for char in text {
            let substituted = layoutSubstitution[char] ?? char
            let method: TypeMethod = CGKeyMap.lookupSequence(substituted) != nil ? .keyEvent : .skip
            // For key-event segments, use the substituted character (US QWERTY equivalent).
            // For skip segments, use the original character.
            let outputChar = method == .keyEvent ? substituted : char

            if method == currentMethod {
                currentText.append(outputChar)
            } else {
                if !currentText.isEmpty {
                    segments.append(TypeSegment(text: currentText, method: currentMethod))
                }
                currentText = String(outputChar)
                currentMethod = method
            }
        }
        if !currentText.isEmpty {
            segments.append(TypeSegment(text: currentText, method: currentMethod))
        }

        return segments
    }

    /// Type text by posting CGEvent keyboard events for each character.
    private func typeViaCGEvent(_ text: String) -> TypeResult? {
        for char in text {
            guard let sequence = CGKeyMap.lookupSequence(char) else {
                return TypeResult(
                    success: false,
                    warning: nil,
                    error: "No key mapping for character '\(char)'"
                )
            }
            guard CGEventInput.postKeySequence(sequence) else {
                return TypeResult(
                    success: false,
                    warning: nil,
                    error: "CGEvent key post failed for '\(char)'"
                )
            }
            usleep(EnvConfig.keystrokeDelayUs)
        }
        return nil // success
    }

    /// Send a special key press (Return, Escape, arrows, etc.) with optional modifiers
    /// via CGEvent keyboard events. Also handles single printable characters with modifiers
    /// (e.g., Cmd+L for Safari address bar).
    func pressKey(keyName: String, modifiers: [String] = []) -> TypeResult {
        if let keyboardError = prepareKeyboardInput(tag: "pressKey") {
            return TypeResult(success: false, warning: nil, error: keyboardError)
        }

        let modStr = modifiers.isEmpty ? "" : " modifiers=\(modifiers.joined(separator: "+"))"
        DebugLog.log("pressKey", "key=\(keyName)\(modStr)")
        ensureTargetFrontmost()

        // Resolve the virtual keycode: try special key names first, then single characters
        let keycode: UInt16
        if let specialCode = AppleScriptKeyMap.keyCode(for: keyName) {
            keycode = specialCode
        } else if keyName.count == 1, let char = keyName.first,
                  let mapping = CGKeyMap.lookup(Character(String(char).lowercased())) {
            keycode = mapping.keycode
        } else {
            return TypeResult(
                success: false, warning: nil,
                error: "Unknown key '\(keyName)'. Supported: \(AppleScriptKeyMap.supportedKeys.joined(separator: ", ")), or a single character.")
        }

        // Map modifier strings to CGEventFlags
        var flags = CGEventFlags()
        for mod in modifiers {
            switch mod.lowercased() {
            case "shift": flags.insert(.maskShift)
            case "command": flags.insert(.maskCommand)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            default:
                return TypeResult(
                    success: false, warning: nil,
                    error: "Unknown modifier '\(mod)'. Supported: shift, command, option, control.")
            }
        }

        let result = CGEventInput.postKey(keycode: keycode, flags: flags)
        DebugLog.log("pressKey", "CGEvent=\(result ? "OK" : "FAILED")")
        if result {
            return TypeResult(success: true, warning: nil, error: nil)
        }
        return TypeResult(success: false, warning: nil, error: "CGEvent press_key failed")
    }
}
