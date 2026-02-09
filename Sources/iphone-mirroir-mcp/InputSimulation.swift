// Copyright 2026 jfarcand
// Licensed under the Apache License, Version 2.0
//
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
/// Requires the Karabiner helper daemon for all input operations (tap, swipe,
/// type, press_key). Keyboard input is sent via Karabiner virtual HID to avoid
/// the Space-switching overhead of AppleScript activation.
final class InputSimulation: @unchecked Sendable {
    private let bridge: MirroringBridge
    let helperClient = HelperClient()
    private let mirroringBundleID = "com.apple.ScreenContinuity"

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

        ensureMirroringFrontmost()

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

        ensureMirroringFrontmost()

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

    /// Long press at a position relative to the mirroring window.
    /// Returns nil on success, or an error message on failure.
    func longPress(x: Double, y: Double, durationMs: Int = 500) -> String? {
        guard let info = bridge.getWindowInfo() else {
            return "iPhone Mirroring window not found"
        }

        guard helperClient.isAvailable else {
            return helperClient.unavailableMessage
        }

        ensureMirroringFrontmost()

        let screenX = Double(info.position.x) + x
        let screenY = Double(info.position.y) + y

        if helperClient.longPress(x: screenX, y: screenY, durationMs: durationMs) {
            return nil
        }
        return "Helper long press failed"
    }

    /// Double-tap at a position relative to the mirroring window.
    /// Returns nil on success, or an error message on failure.
    func doubleTap(x: Double, y: Double) -> String? {
        guard let info = bridge.getWindowInfo() else {
            return "iPhone Mirroring window not found"
        }

        guard helperClient.isAvailable else {
            return helperClient.unavailableMessage
        }

        ensureMirroringFrontmost()

        let screenX = Double(info.position.x) + x
        let screenY = Double(info.position.y) + y

        if helperClient.doubleTap(x: screenX, y: screenY) {
            return nil
        }
        return "Helper double tap failed"
    }

    /// Drag from one point to another relative to the mirroring window.
    /// Unlike swipe (quick flick), drag maintains sustained contact for
    /// rearranging icons, adjusting sliders, and drag-and-drop operations.
    /// Returns nil on success, or an error message on failure.
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int = 1000) -> String? {
        guard let info = bridge.getWindowInfo() else {
            return "iPhone Mirroring window not found"
        }

        guard helperClient.isAvailable else {
            return helperClient.unavailableMessage
        }

        ensureMirroringFrontmost()

        let startX = Double(info.position.x) + fromX
        let startY = Double(info.position.y) + fromY
        let endX = Double(info.position.x) + toX
        let endY = Double(info.position.y) + toY

        if helperClient.drag(fromX: startX, fromY: startY,
                             toX: endX, toY: endY,
                             durationMs: durationMs) {
            return nil
        }
        return "Helper drag failed"
    }

    /// Trigger a shake gesture on the mirrored iPhone.
    /// Sends Ctrl+Cmd+Z which triggers shake-to-undo in iOS apps.
    func shake() -> TypeResult {
        guard helperClient.isAvailable else {
            return TypeResult(success: false, skippedCharacters: "",
                              warning: nil, error: helperClient.unavailableMessage)
        }

        ensureMirroringFrontmost()

        if helperClient.shake() {
            return TypeResult(success: true, skippedCharacters: "",
                              warning: nil, error: nil)
        }
        return TypeResult(success: false, skippedCharacters: "",
                          warning: nil, error: "Helper shake command failed")
    }

    /// Launch an app by name using Spotlight search.
    /// Opens Spotlight, types the app name, waits for results, and presses Return.
    /// Returns nil on success, or an error message on failure.
    func launchApp(name: String) -> String? {
        // Step 1: Open Spotlight via menu action
        guard bridge.triggerMenuAction(menu: "View", item: "Spotlight") else {
            return "Failed to open Spotlight. Is iPhone Mirroring running?"
        }
        usleep(800_000) // 800ms for Spotlight to appear and be ready for input

        // Step 2: Type the app name
        let typeResult = typeText(name)
        guard typeResult.success else {
            return typeResult.error ?? "Failed to type app name"
        }
        usleep(1_000_000) // 1s for search results to populate

        // Step 3: Press Return to launch the top result
        let keyResult = pressKey(keyName: "return")
        guard keyResult.success else {
            return keyResult.error ?? "Failed to press Return"
        }

        return nil
    }

    /// Open a URL on the mirrored iPhone by launching Safari and navigating to it.
    /// Opens Safari via Spotlight, selects the address bar with Cmd+L, types the URL,
    /// and presses Return to navigate.
    /// Returns nil on success, or an error message on failure.
    func openURL(_ url: String) -> String? {
        // Step 1: Launch Safari
        if let error = launchApp(name: "Safari") {
            return error
        }
        usleep(1_500_000) // 1.5s for Safari to fully load

        // Step 2: Select the address bar with Cmd+L (works whether Safari was
        // already open or just launched, and clears any existing URL)
        let selectResult = pressKey(keyName: "l", modifiers: ["command"])
        guard selectResult.success else {
            return selectResult.error ?? "Failed to select address bar"
        }
        usleep(500_000) // 500ms for address bar to activate

        // Step 3: Type the URL
        let typeResult = typeText(url)
        guard typeResult.success else {
            return typeResult.error ?? "Failed to type URL"
        }
        usleep(300_000) // 300ms before pressing Return

        // Step 4: Press Return to navigate
        let goResult = pressKey(keyName: "return")
        guard goResult.success else {
            return goResult.error ?? "Failed to press Return"
        }

        return nil
    }

    /// Ensure iPhone Mirroring is the frontmost app so it receives keyboard input.
    /// Only activates if another app is currently in front, to avoid unnecessary
    /// Space switches. Does NOT restore the previous frontmost app — this eliminates
    /// the "switch, back, switch, back" jitter that the old AppleScript keystroke approach caused.
    ///
    /// Uses AppleScript `set frontmost to true` via System Events because
    /// `NSRunningApplication.activate()` cannot trigger a macOS Space switch
    /// (deprecated in macOS 14 with no replacement for cross-Space activation).
    private func ensureMirroringFrontmost() {
        let frontApp = NSWorkspace.shared.frontmostApplication
        if frontApp?.bundleIdentifier == mirroringBundleID {
            return // already frontmost, no Space switch needed
        }

        let script = NSAppleScript(source: """
            tell application "System Events"
                tell process "iPhone Mirroring"
                    set frontmost to true
                end tell
            end tell
            """)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        usleep(300_000) // 300ms for Space switch to settle
    }

    /// Type text via Karabiner virtual keyboard through the helper daemon.
    /// Activates iPhone Mirroring if needed (at most one Space switch), then
    /// sends characters through the helper's existing `type` command.
    func typeText(_ text: String) -> TypeResult {
        guard helperClient.isAvailable else {
            return TypeResult(success: false, skippedCharacters: "",
                              warning: nil, error: helperClient.unavailableMessage)
        }

        ensureMirroringFrontmost()

        let response = helperClient.type(text: text)
        return TypeResult(
            success: response.ok,
            skippedCharacters: response.skippedCharacters,
            warning: response.warning,
            error: response.ok ? nil : "Helper type command failed"
        )
    }

    /// Send a special key press (Return, Escape, arrows, etc.) with optional modifiers
    /// via Karabiner virtual keyboard through the helper daemon.
    /// Activates iPhone Mirroring if needed (at most one Space switch).
    func pressKey(keyName: String, modifiers: [String] = []) -> TypeResult {
        guard helperClient.isAvailable else {
            return TypeResult(success: false, skippedCharacters: "",
                              warning: nil, error: helperClient.unavailableMessage)
        }

        ensureMirroringFrontmost()

        if helperClient.pressKey(key: keyName, modifiers: modifiers) {
            return TypeResult(success: true, skippedCharacters: "",
                              warning: nil, error: nil)
        }
        return TypeResult(success: false, skippedCharacters: "",
                          warning: nil, error: "Helper press_key command failed")
    }
}
