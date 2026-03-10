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
    let bridge: any WindowBridging
    private let mirroringBundleID: String
    private let cursorMode: CursorMode
    /// Character substitution table for translating between the iPhone's hardware
    /// keyboard layout and US QWERTY. Built once at init from the first non-US
    /// keyboard layout found on the Mac. CGEvent keycodes are physical keys
    /// (layout-independent), same as HID — substitution is still needed.
    let layoutSubstitution: [Character: Character]
    /// When non-nil, mouse events are posted directly to this PID without
    /// moving the system cursor. Only works for regular macOS apps, not
    /// iPhone Mirroring. Resolved at init from MIRROIR_CURSOR_FREE env var.
    let cursorFreePID: pid_t?

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
    func checkMirroringConnected(tag: String) -> String? {
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
    func prepareKeyboardInput(tag: String) -> String? {
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
        guard var info = prep.info else { return prep.error ?? "Unknown error" }

        if let boundsError = validateBounds(x: toX, y: toY, info: info, tag: "swipe") {
            return boundsError
        }

        // After a focus switch, the window is frontmost but not the "key window"
        // for scroll input. Re-query window info AFTER activation to get fresh
        // coordinates, then warp the cursor into the content area. The cursor
        // warp + MayBegin priming in CGEventInput.swipe() engages the scroll
        // subsystem. No click needed — a click risks hitting the title bar or
        // triggering an unwanted iOS action.
        if prep.focusChanged {
            usleep(EnvConfig.spaceSwitchSettleUs)
            if let freshInfo = bridge.getWindowInfo() {
                info = freshInfo
                DebugLog.log("swipe", "re-queried window after focus change: (\(Int(info.position.x)),\(Int(info.position.y)))")
            }
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
    func ensureTargetFrontmost() -> Bool {
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

}
