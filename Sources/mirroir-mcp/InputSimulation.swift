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
    let error: String?
    /// What the caller should know about a successful entry: the text typed is
    /// not what the screen shows (the iPhone autocorrected it, or the field
    /// hides its text). Nil when nothing needs saying.
    var notice: String? = nil
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
    private let cursorMode: CursorMode
    /// The iPhone's hardware keyboard layout: which physical keys type each
    /// character. CGEvent keycodes are physical keys and the iPhone applies its
    /// own layout to them, so text is typed through this table.
    let keyboardLayout: IPhoneKeyboardLayout
    /// The persistent touch contact shared by every target; while it is held,
    /// pointing operations refuse and no escape click is posted.
    let touchSession: TouchSession
    /// The trackpad gesture poster and sender lookup behind pinch and rotate.
    let gestureDevice: GestureDevice
    /// The key and button poster behind hold_keys.
    let heldInputPoster: any HeldInputPosting
    /// Local OCR describer that confirms each `type_text` clipboard paste on
    /// screen and reads Spotlight during `launch_app`, wrapped so a read the
    /// window resized across comes back nil. Nil means no paste can be
    /// confirmed, so any text that needs the clipboard fails rather than being
    /// reported as typed.
    let pasteVerifier: (any ScreenDescribing)?
    /// The key event poster behind type_text and press_key.
    let keyPoster: any KeyEventPosting
    /// The pasteboard type_text pastes unmappable runs through.
    let pasteboard: any PasteboardAccessing
    /// Posts taps and keystrokes straight to the target's window without
    /// making it the front app. Nil sends all input through the HID path,
    /// which brings the target to the front first.
    let windowPoster: (any WindowEventPosting)?
    /// The target's PID right now, or nil when the target is not running.
    ///
    /// Resolved on every read rather than captured at init: the target can
    /// restart under a new PID at any time — an iPhone respring restarts
    /// ScreenContinuity — and a server that outlives that restart would
    /// otherwise aim events at a process that no longer exists.
    var targetPID: pid_t? {
        bridge.findProcess()?.processIdentifier
    }

    /// When non-nil, mouse events are posted directly to this PID without
    /// moving the system cursor. Only works for regular macOS apps, not
    /// iPhone Mirroring. Enabled by the MIRROIR_CURSOR_FREE env var.
    var cursorFreePID: pid_t? {
        EnvConfig.cursorFreeInput ? targetPID : nil
    }

    init(bridge: any WindowBridging, cursorMode: CursorMode = .direct,
         keyboardLayout override: IPhoneKeyboardLayout? = nil,
         touchSession: TouchSession = .shared,
         gestureDevice: GestureDevice = .live,
         heldInputPoster: any HeldInputPosting = CGEventHeldInputPoster(),
         pasteVerifier: (any ScreenDescribing)? = nil,
         keyPoster: any KeyEventPosting = CGEventKeyPoster(),
         pasteboard: any PasteboardAccessing = GeneralPasteboard(),
         windowPoster: (any WindowEventPosting)? = nil) {
        self.bridge = bridge
        self.windowPoster = windowPoster
        // Every read behind a paste check or a Spotlight launch is one the
        // window kept its size across: launching from a landscape app rotates
        // the mirror while Spotlight opens.
        self.pasteVerifier = pasteVerifier.map {
            WindowStableDescriber(wrapping: $0, bridge: bridge)
        }
        self.keyPoster = keyPoster
        self.pasteboard = pasteboard
        self.cursorMode = cursorMode
        self.touchSession = touchSession
        self.gestureDevice = gestureDevice
        self.heldInputPoster = heldInputPoster
        // The configured iPhone layout (settings.json `keyboardLayout` or
        // IPHONE_KEYBOARD_LAYOUT) unless the caller pins one.
        self.keyboardLayout = override ?? IPhoneKeyboardLayout.configured()
    }

    /// Verify that the target window is connected and accepting input.
    /// Returns a state-specific error message if input should be blocked, nil if safe to proceed.
    func checkMirroringConnected(tag: String) -> String? {
        let state = bridge.getState()
        switch state {
        case .connected:
            return nil
        case .paused:
            if let block = (bridge as? MenuActionCapable)?.sessionBlock() {
                DebugLog.log(tag, "ERROR: target paused (\(block.move.rawValue)): \(block.said)")
                return block.refusal(targetName: bridge.targetName)
            }
            DebugLog.log(tag, "ERROR: target paused")
            return "Target '\(bridge.targetName)' is paused. The user must clear the interruption in "
                + "its window on the Mac. No input was sent. " + AgentInstruction.waitForUser
        case .noWindow:
            DebugLog.log(tag, "ERROR: no window")
            return "Target '\(bridge.targetName)' is running but Accessibility reads no window for it: "
                + "the window is closed, or Accessibility permission was revoked (run "
                + "`mirroir-mcp doctor`). No input was sent. " + AgentInstruction.waitForUser
        case .notRunning:
            DebugLog.log(tag, "ERROR: not running")
            return "Target '\(bridge.targetName)' is not running. Launch iPhone Mirroring first."
        }
    }

    /// Report a delivered pointing action honestly when the session stopped
    /// right after it: the action can itself raise an interruption (a camera
    /// dialog, a Continuity prompt). Returns nil when the target is still
    /// connected, else the message to return in place of plain success.
    func checkLivenessAfter(tag: String, action: String) -> String? {
        let state = bridge.getState()
        guard state != .connected else { return nil }
        DebugLog.log(tag, "delivered, then target state=\(state)")
        return "\(action) was delivered, then '\(bridge.targetName)' stopped accepting "
            + "input (\(state)). Describe the screen before the next action."
    }

    /// Free a session suspended by a target interruption (on iPhone Mirroring: the
    /// "iPhone camera is not available from Mac" OK dialog, or the plain "click to
    /// resume" overlay) by running the registered `SessionEscapePlugin`s. The
    /// framework is target-agnostic; the bundled plugins handle iPhone Continuity
    /// dialogs via a real mouse click that frees the session even when CGEvent
    /// input to the device is rejected. Interruptions can re-arm, so it retries.
    /// Returns true if the session is connected (or was never paused).
    func freePausedSession(tag: String) -> Bool {
        guard bridge.getState() == .paused else { return true }
        let click = escapeClick()
        for attempt in 0 ..< EnvConfig.pausedDismissClickAttempts {
            DebugLog.log(tag, "session paused — running escape plugins " +
                "(attempt \(attempt + 1)/\(EnvConfig.pausedDismissClickAttempts))")
            // Try registered escape plugins in order (camera dialog → resume overlay).
            guard SessionEscapeRegistry.attemptEscape(
                bridge: bridge, click: click, tag: tag) else {
                // No plugin recognized this interruption — nothing more to try.
                // A previous attempt's click can still be taking effect (the
                // overlay fades after the session resumes), so give it the
                // resume settle time before reporting the session as paused.
                if attempt > 0 { usleep(EnvConfig.resumeFromPausedUs) }
                return bridge.getState() == .connected
            }
            usleep(EnvConfig.resumeFromPausedUs)
            if bridge.getState() == .connected {
                DebugLog.log(tag, "session freed — now connected")
                return true
            }
        }
        return bridge.getState() == .connected
    }

    /// Ensure the target is connected, first freeing it from any interruption
    /// (via the registered session-escape plugins) if needed, after launching a
    /// target that is not running (`launchIfNotRunning`). Returns nil when
    /// connected (possibly after freeing), or the state error when it still
    /// cannot accept input.
    func ensureConnected(tag: String) -> String? {
        launchIfNotRunning(tag: tag)
        // An escape plugin frees the session with a real click, which would
        // lift a held touch, so a held touch leaves the paused state alone.
        if !touchSession.isHeld, bridge.getState() == .paused {
            _ = freePausedSession(tag: tag)
            // A Connect press leaves the window reading "Connecting to".
            waitForConnection(tag: tag)
        }
        return checkMirroringConnected(tag: tag)
    }

    /// Common preamble for pointing operations (tap, swipe, drag, long press, double tap).
    /// Validates that the target is connected, the window exists, and coordinates are in bounds.
    /// Refuses first while a persistent touch is held (`TouchSession.heldRefusal`), so
    /// every pointing operation shares one refusal and no click can lift the contact.
    /// All pointing operations use CGEvent — no external dependencies.
    /// Returns `(info, focusChanged, nil)` on success, or `(nil, false, errorMessage)` on failure.
    ///
    /// When `ensureTargetFrontmost` triggers an activation, the window can be
    /// repositioned by the WindowServer (Space switch, headless-runner reflow,
    /// stage-manager move). Stale `info.position` then sends CGEvent clicks to
    /// the old location, missing the actual window. The post-activate re-query
    /// ensures every pointing operation uses the window's *current* coordinates.
    ///
    /// `byWindow` marks an operation that can be posted to the window itself
    /// (tap, double tap, long press). When the target has a window poster,
    /// such an operation returns it in `windowPoster` and skips activation
    /// and the point-ownership guard: the event is addressed to the window,
    /// so it cannot land in whatever covers that point, and the user keeps
    /// the front app.
    func preparePointingInput(
        tag: String, x: Double, y: Double, byWindow: Bool = false
    ) -> (info: WindowInfo?, focusChanged: Bool, error: String?, windowPoster: (any WindowEventPosting)?) {
        if let refusal = touchSession.heldRefusal(tool: tag) {
            DebugLog.log(tag, "REJECTED: touch held")
            return (nil, false, refusal, nil)
        }
        if let stateError = ensureConnected(tag: tag) {
            return (nil, false, stateError, nil)
        }

        guard var info = bridge.getWindowInfo() else {
            DebugLog.log(tag, "ERROR: window not found")
            return (nil, false, "Target '\(bridge.targetName)' window not found", nil)
        }

        if let boundsError = validateBounds(x: x, y: y, info: info, tag: tag) {
            return (nil, false, boundsError, nil)
        }

        logWindowState(tag, info)
        if byWindow, let poster = windowDelivery(for: info) {
            DebugLog.log(tag, "posting to window \(info.windowID); front app untouched")
            return (info, false, nil, poster)
        }
        // Make the mirror the key window before the click. A cold click on a
        // window that is not already frontmost is swallowed by macOS
        // click-to-focus — it raises the window instead of reaching the content,
        // so the tap is lost. ensureTargetFrontmost no-ops when the mirror is
        // already active (consecutive taps pay no activation cost) and activates
        // otherwise, which is the only way the click lands. Skipping activation
        // when merely "unobstructed" was tried and reverted — it dropped the tap.
        let changed: Bool
        switch ensureTargetFrontmost() {
        case .alreadyFront: changed = false
        case .activated: changed = true
        case .failed(let reason):
            DebugLog.log(tag, "REJECTED: \(reason)")
            return (nil, false, reason, nil)
        }
        if changed {
            usleep(EnvConfig.spaceSwitchSettleUs)
            if let freshInfo = bridge.getWindowInfo() {
                if freshInfo.position != info.position || freshInfo.size != info.size {
                    DebugLog.log(tag,
                        "post-activate re-query: was=(\(Int(info.position.x)),\(Int(info.position.y))) " +
                        "now=(\(Int(freshInfo.position.x)),\(Int(freshInfo.position.y)))")
                }
                info = freshInfo
            }
        }
        if let covered = checkPointCoverage(tag: tag, info: info, x: x, y: y) {
            return (nil, changed, covered, nil)
        }
        return (info, changed, nil, nil)
    }

    /// Common preamble for keyboard operations (type, press_key, shake, hold_keys).
    /// Validates that the target is connected and brings it to the front.
    /// Keystrokes go to whichever Mac app has focus, so a target that cannot be
    /// confirmed front refuses here rather than typing into the user's app.
    func prepareKeyboardInput(tag: String) -> String? {
        if let stateError = ensureConnected(tag: tag) {
            return stateError
        }
        if case .failed(let reason) = ensureTargetFrontmost() {
            DebugLog.log(tag, "REJECTED: \(reason)")
            return reason
        }
        return nil
    }

    // MARK: - Cursor management

    /// Save the current cursor position if the effective cursor mode requires it.
    /// Per-call override takes precedence over the instance default.
    func saveCursor(mode: CursorMode? = nil) -> CGPoint? {
        guard (mode ?? cursorMode) == .preserving else { return nil }
        return CGEvent(source: nil)?.location
    }

    /// Restore the cursor to a previously saved position.
    func restoreCursor(_ savedPosition: CGPoint?) {
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
        guard DebugLog.enabled else { return }
        let frontApp = RunningAppLocator.frontmostWindowOwner()?.bundleIdentifier ?? "unknown"
        DebugLog.log(tag, "window=(\(Int(info.position.x)),\(Int(info.position.y))) size=\(Int(info.size.width))x\(Int(info.size.height)) frontApp=\(frontApp)")
    }

    /// Tap at a position relative to the target window.
    /// Returns nil on success, or an error message on failure.
    func tap(x: Double, y: Double, cursorMode override: CursorMode? = nil) -> String? {
        let prep = preparePointingInput(tag: "tap", x: x, y: y, byWindow: true)
        guard let info = prep.info else { return prep.error ?? "Unknown error" }
        if let poster = prep.windowPoster {
            let posted = poster.click(at: CGPoint(x: x, y: y), holdUs: CGEventInput.clickHoldUs, in: info)
            DebugLog.log("tap", "relative=(\(x),\(y)) window record=\(posted ? "OK" : "FAILED")")
            guard posted else { return "Window click failed" }
            return checkLivenessAfter(tag: "tap", action: "The tap")
        }

        let saved = saveCursor(mode: override)
        defer { restoreCursor(saved) }

        let screenX = info.position.x + CGFloat(x)
        let screenY = info.position.y + CGFloat(y)
        DebugLog.log("tap", "relative=(\(x),\(y)) screen=(\(Int(screenX)),\(Int(screenY)))")

        let result = CGEventInput.click(at: CGPoint(x: screenX, y: screenY), targetPID: cursorFreePID)
        DebugLog.log("tap", "CGEvent=\(result ? "OK" : "FAILED")")
        guard result else { return "CGEvent click failed" }
        return checkLivenessAfter(tag: "tap", action: "The tap")
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
        guard result else { return "CGEvent swipe failed" }
        return checkLivenessAfter(tag: "swipe", action: "The swipe")
    }

    /// Long press at a position relative to the target window.
    /// Returns nil on success, or an error message on failure.
    func longPress(x: Double, y: Double, durationMs: Int = 500,
                   cursorMode override: CursorMode? = nil) -> String? {
        let prep = preparePointingInput(tag: "longPress", x: x, y: y, byWindow: true)
        guard let info = prep.info else { return prep.error ?? "Unknown error" }
        if let poster = prep.windowPoster {
            let holdUs = UInt32(CGEventInput.safeDurationMs(durationMs)) * 1000
            let posted = poster.click(at: CGPoint(x: x, y: y), holdUs: holdUs, in: info)
            DebugLog.log("longPress", "relative=(\(x),\(y)) duration=\(durationMs)ms window record=\(posted ? "OK" : "FAILED")")
            guard posted else { return "Window long press failed" }
            return checkLivenessAfter(tag: "longPress", action: "The long press")
        }

        let saved = saveCursor(mode: override)
        defer { restoreCursor(saved) }

        let screenX = Double(info.position.x) + x
        let screenY = Double(info.position.y) + y
        DebugLog.log("longPress", "relative=(\(x),\(y)) screen=(\(Int(screenX)),\(Int(screenY))) duration=\(durationMs)ms")

        let result = CGEventInput.longPress(at: CGPoint(x: screenX, y: screenY), durationMs: durationMs, targetPID: cursorFreePID)
        DebugLog.log("longPress", "CGEvent=\(result ? "OK" : "FAILED")")
        guard result else { return "CGEvent long press failed" }
        return checkLivenessAfter(tag: "longPress", action: "The long press")
    }

    /// Double-tap at a position relative to the target window.
    /// Returns nil on success, or an error message on failure.
    func doubleTap(x: Double, y: Double, cursorMode override: CursorMode? = nil) -> String? {
        let prep = preparePointingInput(tag: "doubleTap", x: x, y: y, byWindow: true)
        guard let info = prep.info else { return prep.error ?? "Unknown error" }
        if let poster = prep.windowPoster {
            let posted = poster.doubleClick(at: CGPoint(x: x, y: y), gapUs: CGEventInput.clickHoldUs, in: info)
            DebugLog.log("doubleTap", "relative=(\(x),\(y)) window record=\(posted ? "OK" : "FAILED")")
            guard posted else { return "Window double tap failed" }
            return checkLivenessAfter(tag: "doubleTap", action: "The double tap")
        }

        let saved = saveCursor(mode: override)
        defer { restoreCursor(saved) }

        let screenX = Double(info.position.x) + x
        let screenY = Double(info.position.y) + y
        DebugLog.log("doubleTap", "relative=(\(x),\(y)) screen=(\(Int(screenX)),\(Int(screenY)))")

        let result = CGEventInput.doubleTap(at: CGPoint(x: screenX, y: screenY), targetPID: cursorFreePID)
        DebugLog.log("doubleTap", "CGEvent=\(result ? "OK" : "FAILED")")
        guard result else { return "CGEvent double tap failed" }
        return checkLivenessAfter(tag: "doubleTap", action: "The double tap")
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
        guard result else { return "CGEvent drag failed" }
        return checkLivenessAfter(tag: "drag", action: "The drag")
    }
}
