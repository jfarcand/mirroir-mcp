// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: System-boundary protocols for the target window and its session: discovery, state, menu actions,
// ABOUTME: the live iPhone Mirroring probes and the plugins that clear an interruption.

import AppKit
import CoreGraphics
import Foundation
import HelperLib

/// Abstracts window discovery and state detection for any target window.
protocol WindowBridging: Sendable {
    /// Display name of this target (e.g. "iphone", "android").
    var targetName: String { get }
    func findProcess() -> NSRunningApplication?
    func getWindowInfo() -> WindowInfo?
    func getState() -> WindowState
    func getOrientation() -> DeviceOrientation?
    /// Bring the target window to the front so it receives input.
    func activate()
    /// Whether the target owns the frontmost window right now, so keyboard
    /// events posted to the HID tap reach it rather than another Mac app.
    func isFrontmost() -> Bool
}

extension WindowBridging {
    /// Default: the target's process has a window in front of every normal
    /// window (it owns the frontmost one, or floats above them), asked of the
    /// window server on every call rather than NSWorkspace's snapshot, which
    /// freezes in the server (see `RunningAppLocator`). An unbundled target
    /// with no running-application record is identified by its window's owner
    /// PID.
    func isFrontmost() -> Bool {
        guard let pid = findProcess()?.processIdentifier ?? getWindowInfo()?.pid
        else { return false }
        return WindowListHelper.isInFront(
            pid: pid, entries: WindowListHelper.windowEntries(onScreenOnly: true))
    }
}

/// Extends WindowBridging with menu bar actions available on iPhone Mirroring.
protocol MenuActionCapable: WindowBridging {
    func triggerMenuAction(menu: String, item: String) -> Bool
    func pressResume() -> Bool
    /// Screen-coordinate center of the dismiss button on a Continuity interruption
    /// overlay (e.g. the "iPhone camera is not available from Mac" OK dialog, or
    /// the plain "click to resume" overlay) while the session is paused. A real
    /// mouse click here frees the session even when CGEvent input to the iPhone is
    /// rejected and AX-press is inert. Returns nil when not paused / no button found.
    func pausedDismissButtonPoint() -> CGPoint?
    /// What blocks the session while it is paused: the interstitial's words
    /// and the move that frees it. Nil while the session accepts input.
    func sessionBlock() -> SessionBlock?
    /// Launch the target app without making it active. Returns whether the
    /// launch request was accepted.
    func launchInBackground() -> Bool
}

extension MenuActionCapable {
    /// Default: no overlay button (non-mirroring bridges have no paused overlay).
    func pausedDismissButtonPoint() -> CGPoint? { nil }
    /// Default: nothing to quote (non-mirroring bridges have no interstitial).
    func sessionBlock() -> SessionBlock? { nil }
    /// Default: nothing to launch (non-mirroring bridges are started by the user).
    func launchInBackground() -> Bool { false }
}

/// Live reads of the iPhone Mirroring process and window from macOS: Launch
/// Services for the process, Accessibility for the main window, the window
/// server for authoritative bounds. Every call answers from current system
/// state — implementations never cache — because the window moves and resizes
/// when the iPhone rotates or Mirroring is resized, and the process gets a new
/// PID when Mirroring restarts.
protocol MirroringSystemProbing: Sendable {
    /// PID of the running app with `bundleID`, or nil when it is not running.
    func processID(bundleID: String) -> pid_t?
    /// Snapshot of the app's AX main window, or nil when it exposes none.
    func mainWindow(pid: pid_t) -> MirroringAXWindow?
    /// Whether the app has a window minimized to the Dock.
    func hasMinimizedWindow(pid: pid_t) -> Bool
    /// Whether the Mac's screen is locked: no window can be read or reached then.
    func isMacScreenLocked() -> Bool
    /// Whether the app is hidden (Cmd+H): its window can be read, not reached.
    func isAppHidden(pid: pid_t) -> Bool
    /// The window server's current window list.
    func windowList() -> [WindowListEntry]
    /// Press the resume control of the paused overlay in the main window of
    /// `pid`: a button `MirroringWindowResolver.isResumeControl` accepts,
    /// directly under the hosting view. Returns whether a press succeeded.
    func pressResumeControl(pid: pid_t) -> Bool
    /// Screen centre of a resume or dismiss control anywhere in the main
    /// window of `pid`, or nil when no interruption overlay shows one.
    func dismissControlPoint(pid: pid_t) -> CGPoint?
    /// Un-minimize and raise the main window of `pid`. Returns whether the raise
    /// was accepted.
    func raiseMainWindow(pid: pid_t) -> Bool
    /// Whether window `windowID` shows a blank frame right now. True when it
    /// cannot be captured: an unreadable frame is no evidence of a live session.
    func frameIsBlank(windowID: CGWindowID) -> Bool
    /// Launch the app with `bundleID` without activating it. Returns whether
    /// Launch Services accepted the request.
    func launchInBackground(bundleID: String) -> Bool
}

/// A pluggable strategy for clearing a target interruption that blocks input —
/// for ANY target, not just iPhone Mirroring. Examples: a suspended iPhone
/// Mirroring session (Continuity camera dialog / resume overlay), or a modal
/// overlay on a generic window target. Registered plugins are tried in order
/// whenever input is blocked; the first that recognizes the current state and
/// acts wins, then the caller re-checks. Add a handler for a new target or
/// interruption by conforming a type and registering it in `SessionEscapeRegistry`.
///
/// Plugins receive the generic `WindowBridging` and narrow to a capability they
/// need (e.g. `as? MenuActionCapable` for iPhone Mirroring), returning false when
/// the target isn't theirs — so target-specific plugins coexist in one registry.
protocol SessionEscapePlugin: Sendable {
    /// Stable identifier for logging.
    var id: String { get }
    /// Attempt to clear the interruption this plugin handles. Returns true if it
    /// recognized the current state and performed its escape action; false if it
    /// does not apply (wrong target, or its interruption isn't shown). `click`
    /// posts a real mouse click at a screen point (which, on iPhone Mirroring,
    /// frees Continuity dialogs even while CGEvent input to the device is rejected).
    func attemptEscape(bridge: any WindowBridging, click: (CGPoint) -> Void, tag: String) -> Bool
}

// MARK: - Conformances

extension MirroringBridge: MenuActionCapable {}
