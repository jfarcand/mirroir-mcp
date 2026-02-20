// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Simulates user input (tap, swipe, keyboard) on the iPhone Mirroring window.
// ABOUTME: Delegates to the privileged Karabiner helper daemon for taps and swipes.

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

/// Simulates touch and keyboard input on the iPhone Mirroring window.
/// All coordinates are relative to the mirroring window's content area.
///
/// Requires the Karabiner helper daemon for all input operations (tap, swipe,
/// type, press_key). Keyboard input is sent via Karabiner virtual HID to avoid
/// the Space-switching overhead of AppleScript activation.
final class InputSimulation: Sendable {
    private let bridge: MirroringBridge
    let helperClient = HelperClient()
    private let mirroringBundleID = EnvConfig.mirroringBundleID
    /// Character substitution table for translating between the iPhone's hardware
    /// keyboard layout and US QWERTY (used by the HID helper). Built once at init
    /// from the first non-US keyboard layout found on the Mac.
    private let layoutSubstitution: [Character: Character]

    init(bridge: MirroringBridge) {
        self.bridge = bridge

        // Build layout substitution table if a non-US layout is installed.
        // The iPhone's hardware keyboard layout typically matches one of the
        // Mac's installed layouts. When it differs from US QWERTY, characters
        // need translation before sending through the HID helper.
        if let usData = LayoutMapper.layoutData(forSourceID: "com.apple.keylayout.US"),
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

    /// Verify that iPhone Mirroring is connected and accepting input.
    /// Returns an error message if input should be blocked, nil if safe to proceed.
    private func checkMirroringConnected(tag: String) -> String? {
        let state = bridge.getState()
        guard state == .connected else {
            DebugLog.log(tag, "ERROR: mirroring not connected (state: \(state))")
            return "iPhone Mirroring is not connected. Is the phone locked or the app closed?"
        }
        return nil
    }

    /// Common preamble for coordinate-based input operations.
    /// Validates that mirroring is connected, the helper is available, the window exists,
    /// coordinates are in bounds, then logs window state and ensures mirroring is frontmost.
    /// Returns `(info, nil)` on success, or `(nil, errorMessage)` on failure.
    private func prepareInput(tag: String, x: Double, y: Double) -> (info: WindowInfo?, error: String?) {
        if let stateError = checkMirroringConnected(tag: tag) {
            return (nil, stateError)
        }

        guard let info = bridge.getWindowInfo() else {
            DebugLog.log(tag, "ERROR: window not found")
            return (nil, "iPhone Mirroring window not found")
        }

        guard helperClient.isAvailable else {
            DebugLog.log(tag, "ERROR: helper unavailable")
            return (nil, helperClient.unavailableMessage)
        }

        if let boundsError = validateBounds(x: x, y: y, info: info, tag: tag) {
            return (nil, boundsError)
        }

        logWindowState(tag, info)
        ensureMirroringFrontmost()
        return (info, nil)
    }

    /// Validate that coordinates fall within the iPhone Mirroring window bounds.
    /// Returns nil if valid, or a descriptive error message if out of bounds.
    func validateBounds(x: Double, y: Double, info: WindowInfo, tag: String) -> String? {
        let w = Double(info.size.width)
        let h = Double(info.size.height)
        if x < 0 || x > w || y < 0 || y > h {
            let msg = "Coordinates (\(Int(x)), \(Int(y))) are outside the iPhone Mirroring window (\(Int(w))x\(Int(h))). x must be 0-\(Int(w)), y must be 0-\(Int(h))."
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

    /// Tap at a position relative to the mirroring window.
    /// Returns nil on success, or an error message if the helper is unavailable.
    func tap(x: Double, y: Double) -> String? {
        let prep = prepareInput(tag: "tap", x: x, y: y)
        guard let info = prep.info else { return prep.error }

        let screenX = info.position.x + CGFloat(x)
        let screenY = info.position.y + CGFloat(y)
        DebugLog.log("tap", "relative=(\(x),\(y)) screen=(\(Int(screenX)),\(Int(screenY)))")

        let result = helperClient.click(x: Double(screenX), y: Double(screenY))
        DebugLog.log("tap", "helperClick=\(result ? "OK" : "FAILED")")
        return result ? nil : "Helper click failed"
    }

    /// Swipe from one point to another relative to the mirroring window.
    /// Returns nil on success, or an error message if the helper is unavailable.
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int = 300)
        -> String?
    {
        let prep = prepareInput(tag: "swipe", x: fromX, y: fromY)
        guard let info = prep.info else { return prep.error }

        if let boundsError = validateBounds(x: toX, y: toY, info: info, tag: "swipe") {
            return boundsError
        }

        let startX = Double(info.position.x) + fromX
        let startY = Double(info.position.y) + fromY
        let endX = Double(info.position.x) + toX
        let endY = Double(info.position.y) + toY

        DebugLog.log("swipe", "from=(\(fromX),\(fromY))->(\(toX),\(toY)) screen=(\(Int(startX)),\(Int(startY)))->(\(Int(endX)),\(Int(endY))) duration=\(durationMs)ms")

        let result = helperClient.swipe(fromX: startX, fromY: startY,
                              toX: endX, toY: endY,
                              durationMs: durationMs)
        DebugLog.log("swipe", "helper=\(result ? "OK" : "FAILED")")
        return result ? nil : "Helper swipe failed"
    }

    /// Long press at a position relative to the mirroring window.
    /// Returns nil on success, or an error message on failure.
    func longPress(x: Double, y: Double, durationMs: Int = 500) -> String? {
        let prep = prepareInput(tag: "longPress", x: x, y: y)
        guard let info = prep.info else { return prep.error }

        let screenX = Double(info.position.x) + x
        let screenY = Double(info.position.y) + y
        DebugLog.log("longPress", "relative=(\(x),\(y)) screen=(\(Int(screenX)),\(Int(screenY))) duration=\(durationMs)ms")

        let result = helperClient.longPress(x: screenX, y: screenY, durationMs: durationMs)
        DebugLog.log("longPress", "helper=\(result ? "OK" : "FAILED")")
        return result ? nil : "Helper long press failed"
    }

    /// Double-tap at a position relative to the mirroring window.
    /// Returns nil on success, or an error message on failure.
    func doubleTap(x: Double, y: Double) -> String? {
        let prep = prepareInput(tag: "doubleTap", x: x, y: y)
        guard let info = prep.info else { return prep.error }

        let screenX = Double(info.position.x) + x
        let screenY = Double(info.position.y) + y
        DebugLog.log("doubleTap", "relative=(\(x),\(y)) screen=(\(Int(screenX)),\(Int(screenY)))")

        let result = helperClient.doubleTap(x: screenX, y: screenY)
        DebugLog.log("doubleTap", "helper=\(result ? "OK" : "FAILED")")
        return result ? nil : "Helper double tap failed"
    }

    /// Drag from one point to another relative to the mirroring window.
    /// Unlike swipe (quick flick), drag maintains sustained contact for
    /// rearranging icons, adjusting sliders, and drag-and-drop operations.
    /// Returns nil on success, or an error message on failure.
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int = 1000) -> String? {
        let prep = prepareInput(tag: "drag", x: fromX, y: fromY)
        guard let info = prep.info else { return prep.error }

        if let boundsError = validateBounds(x: toX, y: toY, info: info, tag: "drag") {
            return boundsError
        }

        let startX = Double(info.position.x) + fromX
        let startY = Double(info.position.y) + fromY
        let endX = Double(info.position.x) + toX
        let endY = Double(info.position.y) + toY

        DebugLog.log("drag", "from=(\(fromX),\(fromY))->(\(toX),\(toY)) screen=(\(Int(startX)),\(Int(startY)))->(\(Int(endX)),\(Int(endY))) duration=\(durationMs)ms")

        let result = helperClient.drag(fromX: startX, fromY: startY,
                             toX: endX, toY: endY,
                             durationMs: durationMs)
        DebugLog.log("drag", "helper=\(result ? "OK" : "FAILED")")
        return result ? nil : "Helper drag failed"
    }

    /// Trigger a shake gesture on the mirrored iPhone.
    /// Sends Ctrl+Cmd+Z which triggers shake-to-undo in iOS apps.
    func shake() -> TypeResult {
        if let stateError = checkMirroringConnected(tag: "shake") {
            return TypeResult(success: false, warning: nil, error: stateError)
        }
        guard helperClient.isAvailable else {
            DebugLog.log("shake", "ERROR: helper unavailable")
            return TypeResult(success: false,
                              warning: nil, error: helperClient.unavailableMessage)
        }

        DebugLog.log("shake", "sending shake gesture")
        ensureMirroringFrontmost()

        let result = helperClient.shake()
        DebugLog.log("shake", "helper=\(result ? "OK" : "FAILED")")
        if result {
            return TypeResult(success: true, warning: nil, error: nil)
        }
        return TypeResult(success: false, warning: nil, error: "Helper shake command failed")
    }

    /// Launch an app by name using Spotlight search.
    /// Opens Spotlight, types the app name, waits for results, and presses Return.
    /// Returns nil on success, or an error message on failure.
    func launchApp(name: String) -> String? {
        if let stateError = checkMirroringConnected(tag: "launchApp") {
            return stateError
        }
        DebugLog.log("launchApp", "launching '\(name)'")

        // Step 1: Open Spotlight via menu action
        guard bridge.triggerMenuAction(menu: "View", item: "Spotlight") else {
            DebugLog.log("launchApp", "ERROR: failed to open Spotlight")
            return "Failed to open Spotlight. Is iPhone Mirroring running?"
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

    /// Ensure iPhone Mirroring is the frontmost app so it receives keyboard input.
    /// Always runs AppleScript activation because NSWorkspace.frontmostApplication
    /// can report stale values when another app gained keyboard focus between MCP
    /// calls. The activation is idempotent (~10ms no-op when already front).
    /// Only sleeps 300ms when a real Space switch was needed.
    ///
    /// Does NOT restore the previous frontmost app — this eliminates
    /// the "switch, back, switch, back" jitter that the old AppleScript keystroke approach caused.
    ///
    /// Uses AppleScript `set frontmost to true` via System Events because
    /// `NSRunningApplication.activate()` cannot trigger a macOS Space switch
    /// (deprecated in macOS 14 with no replacement for cross-Space activation).
    private func ensureMirroringFrontmost() {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let alreadyFront = frontApp?.bundleIdentifier == mirroringBundleID

        if alreadyFront {
            DebugLog.log("focus", "likely frontmost, re-confirming")
        } else {
            DebugLog.log("focus", "switching from \(frontApp?.bundleIdentifier ?? "nil")")
        }

        // Always activate — NSWorkspace.frontmostApplication can report stale
        // values when another app gained keyboard focus between MCP calls.
        let processName = EnvConfig.mirroringProcessName
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

        // Only wait for Space switch when we weren't already frontmost.
        // When already front, the AppleScript is a no-op and needs no settling time.
        if !alreadyFront {
            usleep(EnvConfig.spaceSwitchSettleUs)
        }

        let afterApp = NSWorkspace.shared.frontmostApplication
        DebugLog.log("focus", "after activation frontApp=\(afterApp?.bundleIdentifier ?? "nil")")
    }

    /// Type text via Karabiner HID keycodes.
    ///
    /// The Karabiner virtual HID presents as a US ANSI keyboard, so iOS
    /// interprets keycodes as US QWERTY by default. When `IPHONE_KEYBOARD_LAYOUT`
    /// is set to a non-US layout, characters are translated through a layout
    /// substitution table before sending to the HID helper. Characters with no
    /// HID mapping are skipped and reported in the warning field of the result.
    ///
    /// HID segments longer than 15 characters are sent in chunks to stay within
    /// the Karabiner HID report buffer capacity.
    func typeText(_ text: String) -> TypeResult {
        if let stateError = checkMirroringConnected(tag: "typeText") {
            return TypeResult(success: false, warning: nil, error: stateError)
        }
        guard helperClient.isAvailable else {
            DebugLog.log("typeText", "ERROR: helper unavailable")
            return TypeResult(success: false,
                              warning: nil, error: helperClient.unavailableMessage)
        }

        DebugLog.log("typeText", "typing \(text.count) char(s): \(text.prefix(50))")
        ensureMirroringFrontmost()

        // Split text into segments: HID-typeable (substituted) vs paste-needed (original).
        let segments = buildTypeSegments(text)
        var skippedChars = ""

        for segment in segments {
            switch segment.method {
            case .hid:
                if let error = typeViaHID(segment.text) {
                    return error
                }
            case .paste:
                // No working paste mechanism — collect skipped characters for the warning
                skippedChars += segment.text
                fputs("InputSimulation: skipping \(segment.text.count) char(s) with no HID mapping: \(segment.text)\n", stderr)
            }
        }

        if !skippedChars.isEmpty {
            return TypeResult(
                success: true,
                warning: "Skipped \(skippedChars.count) character(s) with no HID mapping: \(skippedChars)",
                error: nil
            )
        }
        return TypeResult(success: true, warning: nil, error: nil)
    }

    /// A segment of text to be typed, with the method to use.
    enum TypeMethod { case hid, paste }
    struct TypeSegment {
        let text: String
        let method: TypeMethod
    }

    /// Split text into segments based on whether each character can be typed via HID
    /// (after layout substitution) or needs clipboard paste.
    func buildTypeSegments(_ text: String) -> [TypeSegment] {
        var segments: [TypeSegment] = []
        var currentText = ""
        var currentMethod: TypeMethod = .hid

        for char in text {
            let substituted = layoutSubstitution[char] ?? char
            let method: TypeMethod = HIDKeyMap.lookupSequence(substituted) != nil ? .hid : .paste
            // For HID segments, use the substituted character (US QWERTY equivalent).
            // For paste segments, use the original character (paste is layout-independent).
            let outputChar = method == .hid ? substituted : char

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

    /// Type text via Karabiner HID in 15-character chunks.
    private func typeViaHID(_ text: String) -> TypeResult? {
        let chunkSize = EnvConfig.hidTypingChunkSize
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: chunkSize,
                                 limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[index..<end])

            let response = helperClient.type(text: chunk)
            guard response.ok else {
                return TypeResult(
                    success: false,
                    warning: response.warning,
                    error: "Helper type command failed"
                )
            }

            index = end
        }
        return nil // success
    }

    /// Send a special key press (Return, Escape, arrows, etc.) with optional modifiers
    /// via Karabiner virtual keyboard through the helper daemon.
    /// Activates iPhone Mirroring if needed (at most one Space switch).
    func pressKey(keyName: String, modifiers: [String] = []) -> TypeResult {
        if let stateError = checkMirroringConnected(tag: "pressKey") {
            return TypeResult(success: false, warning: nil, error: stateError)
        }
        guard helperClient.isAvailable else {
            DebugLog.log("pressKey", "ERROR: helper unavailable")
            return TypeResult(success: false,
                              warning: nil, error: helperClient.unavailableMessage)
        }

        let modStr = modifiers.isEmpty ? "" : " modifiers=\(modifiers.joined(separator: "+"))"
        DebugLog.log("pressKey", "key=\(keyName)\(modStr)")
        ensureMirroringFrontmost()

        let result = helperClient.pressKey(key: keyName, modifiers: modifiers)
        DebugLog.log("pressKey", "helper=\(result ? "OK" : "FAILED")")
        if result {
            return TypeResult(success: true, warning: nil, error: nil)
        }
        return TypeResult(success: false, warning: nil, error: "Helper press_key command failed")
    }
}
