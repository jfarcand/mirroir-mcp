// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Bridge to the macOS iPhone Mirroring app (com.apple.ScreenContinuity).
// ABOUTME: Uses AXUIElement APIs to find the window, detect state, and trigger menu actions.

import AppKit
import ApplicationServices
import HelperLib
import os

/// Device orientation based on mirroring window dimensions.
enum DeviceOrientation: String, Sendable {
    case portrait
    case landscape

    /// Orientation of a window with `size`: portrait when taller than wide.
    /// The mirroring window takes the iPhone's aspect ratio, so its live size
    /// tells the orientation.
    init(size: CGSize) {
        self = size.height > size.width ? .portrait : .landscape
    }
}

/// Connection state of a target window (iPhone Mirroring or generic window).
enum WindowState: String, Sendable, Codable {
    case connected
    case paused
    case notRunning
    case noWindow
    /// The app is running and its window is minimized to the Dock: nothing can
    /// be read from it or sent to it until someone brings it back.
    case minimized
}

/// Backward-compatible alias for code that references the old name.
typealias MirroringState = WindowState

/// Information about the mirroring window position and size.
struct WindowInfo: Sendable {
    let windowID: CGWindowID
    let position: CGPoint
    let size: CGSize
    let pid: pid_t

    /// Device orientation implied by this window's size.
    var orientation: DeviceOrientation { DeviceOrientation(size: size) }
}

/// Bridge to interact with the iPhone Mirroring app via macOS accessibility APIs.
/// The iPhone Mirroring window is special — it does not appear in AXWindows
/// but is accessible via AXMainWindow/AXFocusedWindow.
///
/// Every query resolves from live system state through `probe`: the process
/// by bundle ID, the window's geometry and overlay from fresh AX and
/// window-server reads. Nothing is kept between calls, so answers follow the
/// window through iPhone rotations and resizes and the process through a
/// Mirroring restart under a new PID.
final class MirroringBridge: Sendable {
    let targetName: String
    private let bundleIdentifier: String
    private let probe: any MirroringSystemProbing
    /// Whether the app has been seen running since this server started. Once
    /// it has, its absence means someone quit it, and a quit is honoured.
    private let hasBeenRunning = OSAllocatedUnfairLock(initialState: false)

    init(targetName: String = "iphone",
         bundleID: String? = nil,
         probe: any MirroringSystemProbing = LiveMirroringProbe()) {
        self.targetName = targetName
        self.bundleIdentifier = bundleID ?? EnvConfig.mirroringBundleID
        self.probe = probe
    }

    /// PID of the iPhone Mirroring process right now, or nil when not running.
    private var processID: pid_t? {
        let pid = probe.processID(bundleID: bundleIdentifier)
        if pid != nil { hasBeenRunning.withLock { $0 = true } }
        return pid
    }

    /// Whether the app ran during this server's life and is gone now: the
    /// user quit it (or it died), and that is a stop, not a state to repair.
    var wasQuit: Bool {
        processID == nil && hasBeenRunning.withLock { $0 }
    }

    /// Find the iPhone Mirroring process.
    ///
    /// Resolved live on every call: a device respring or a Mirroring relaunch
    /// restarts ScreenContinuity under a new PID, and the long-lived server must
    /// follow it rather than keep querying AX against the process that died.
    func findProcess() -> NSRunningApplication? {
        processID.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    /// Get the window info including CGWindowID for screenshots.
    ///
    /// Prefers CGWindowList bounds over AX geometry because AX can lag the
    /// WindowServer's actual window after scenario / focus switches (observed
    /// empirically on macos-15 CI runners — AX returned a stale position while
    /// CGEvent posting landed at the window's true location). CGWindowList
    /// reflects the compositor's authoritative bounds; see
    /// `MirroringWindowResolver.windowInfo` for how the window is identified.
    func getWindowInfo() -> WindowInfo? {
        guard let pid = processID, let window = probe.mainWindow(pid: pid) else { return nil }
        return MirroringWindowResolver.windowInfo(
            pid: pid, axWindow: window, windowList: probe.windowList())
    }

    /// Detect the current mirroring connection state.
    func getState() -> MirroringState {
        guard let pid = processID else { return .notRunning }
        guard let window = probe.mainWindow(pid: pid) else {
            // A minimized window is no longer the app's main window, so it reads
            // like a closed one unless the window list is asked.
            return probe.hasMinimizedWindow(pid: pid) ? .minimized : .noWindow
        }
        return MirroringWindowResolver.state(of: window) {
            let windowID = MirroringWindowResolver.windowInfo(
                pid: pid, axWindow: window, windowList: probe.windowList())?.windowID ?? 0
            let blank = probe.frameIsBlank(windowID: windowID)
            DebugLog.log("state", "unlabeled controls only; frame blank=\(blank)")
            return blank
        }
    }

    /// Press the resume control of the paused overlay.
    ///
    /// Presses only a button whose title `MirroringWindowResolver.isResumeControl`
    /// accepts (a known resume/dismiss title). An unlabeled button is left alone:
    /// pressing the overlay's first unlabeled button can be a close/quit control
    /// that terminates the app, so it is never pressed. The lookup and the press
    /// go through `probe`, the same reads `getState` classifies.
    func pressResume() -> Bool {
        guard let pid = processID, !showsCredentialPrompt(pid: pid) else { return false }
        return probe.pressResumeControl(pid: pid)
    }

    /// Screen-center of the overlay's *dismiss* button (e.g. the camera dialog's
    /// "OK"), located by title so we don't click a stray titlebar/toolbar control.
    /// Nil while a credential prompt shows: its "OK" would submit the prompt.
    /// See `MenuActionCapable.pausedDismissButtonPoint`.
    func pausedDismissButtonPoint() -> CGPoint? {
        guard let pid = processID, !showsCredentialPrompt(pid: pid) else { return nil }
        return probe.dismissControlPoint(pid: pid)
    }

    /// Launch iPhone Mirroring without making it active: the user's front app
    /// keeps the focus while the session connects. Only an app this server
    /// never saw running is launched: one that was quit stays quit, so that
    /// quitting iPhone Mirroring stops an agent.
    func launchInBackground() -> Bool {
        if wasQuit {
            DebugLog.log("launch", "\(bundleIdentifier) was quit while this server ran; not reopened")
            return false
        }
        let accepted = probe.launchInBackground(bundleID: bundleIdentifier)
        DebugLog.log("launch", "background launch of \(bundleIdentifier): \(accepted ? "requested" : "refused")")
        return accepted
    }

    /// What keeps the session from taking input, and the move that frees it:
    /// what a paused window says, a connected app that is hidden, or an app
    /// that was quit. Nil while the session accepts input or has no window to read.
    func sessionBlock() -> SessionBlock? {
        guard let pid = processID else {
            return wasQuit ? SessionBlock(quoted: [], move: .reopenAfterQuit) : nil
        }
        let state = getState()
        // Measured on macOS 26.5: a hidden app still shows live frames, and a
        // tap or a swipe posted to its window changes nothing on the iPhone.
        if state == .connected, probe.isAppHidden(pid: pid) {
            return SessionBlock(quoted: [], move: .showMirroring)
        }
        guard state == .paused, let window = probe.mainWindow(pid: pid) else { return nil }
        let block = SessionBlockClassifier.block(of: window)
        // A locked Mac makes every window unreadable. Reopening iPhone
        // Mirroring would not help; unlocking the Mac does.
        if block.move == .reopenMirroring, probe.isMacScreenLocked() {
            return SessionBlock(quoted: [], move: .unlockMac)
        }
        return block
    }

    /// Whether a password or Touch ID prompt shows over the mirroring window.
    private func showsCredentialPrompt(pid: pid_t) -> Bool {
        guard let window = probe.mainWindow(pid: pid) else { return false }
        let showing = SessionBlockClassifier.hasCredentialPrompt(window)
        if showing { DebugLog.log("resume", "credential prompt showing — nothing is pressed") }
        return showing
    }

    /// Trigger a menu bar action (e.g., View > Home Screen).
    ///
    /// Uses an exact-string match on AX menu and item titles. On non-English
    /// macOS locales iPhone Mirroring's menu titles are translated and the
    /// AX lookup misses; for the three View-menu navigation items the
    /// Cmd+digit keyboard shortcuts are locale-invariant, so the bridge
    /// falls back to CGEvent in that case (issue #23).
    func triggerMenuAction(menu menuName: String, item itemName: String) -> Bool {
        if axTriggerMenuAction(menu: menuName, item: itemName) {
            return true
        }
        if let shortcut = MenuShortcuts.viewNavShortcut(for: itemName) {
            DebugLog.log("menu", "AX miss for '\(menuName)' > '\(itemName)' (likely localized title) — falling back to Cmd+\(shortcut.label)")
            return triggerKeyboardShortcut(keycode: shortcut.keycode)
        }
        return false
    }

    private func axTriggerMenuAction(menu menuName: String, item itemName: String) -> Bool {
        guard let app = findProcess() else { return false }
        let pid = app.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)

        var menuBarValue: CFTypeRef?
        let menuBarResult = AXUIElementCopyAttributeValue(
            appRef, kAXMenuBarAttribute as CFString, &menuBarValue
        )
        guard menuBarResult == .success,
              let menuBarRef = menuBarValue,
              CFGetTypeID(menuBarRef) == AXUIElementGetTypeID()
        else { return false }
        let menuBar = unsafeDowncast(menuBarRef, to: AXUIElement.self)

        var menuBarChildren: CFTypeRef?
        AXUIElementCopyAttributeValue(
            menuBar, kAXChildrenAttribute as CFString, &menuBarChildren
        )
        guard let menuBarItems = menuBarChildren as? [AXUIElement] else { return false }

        for menuBarItem in menuBarItems {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(menuBarItem, kAXTitleAttribute as CFString, &title)
            guard let t = title as? String, t == menuName else { continue }

            var submenuValue: CFTypeRef?
            AXUIElementCopyAttributeValue(
                menuBarItem, kAXChildrenAttribute as CFString, &submenuValue
            )
            guard let submenus = submenuValue as? [AXUIElement],
                  let submenu = submenus.first
            else { continue }

            var itemsValue: CFTypeRef?
            AXUIElementCopyAttributeValue(
                submenu, kAXChildrenAttribute as CFString, &itemsValue
            )
            guard let items = itemsValue as? [AXUIElement] else { continue }

            for item in items {
                var itemTitle: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitle)
                if let it = itemTitle as? String, it == itemName {
                    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    return result == .success
                }
            }
        }
        return false
    }

    /// Send a Cmd+<key> keyboard shortcut to iPhone Mirroring via CGEvent.
    /// Activates the app first so the event reaches the right window.
    private func triggerKeyboardShortcut(keycode: UInt16) -> Bool {
        guard let app = findProcess() else { return false }
        // `isActive` on the freshly resolved app, not NSWorkspace's frontmost
        // application: that snapshot is frozen in the server (see
        // `RunningAppLocator`), and believing it would send the shortcut to
        // whichever app actually holds focus.
        let alreadyFront = app.isActive
        if !alreadyFront {
            app.activate()
            usleep(EnvConfig.spaceSwitchSettleUs)
        }
        // The chord goes to whichever app holds focus. If activation did not
        // take, another app would get Command and its release, so nothing is
        // posted. Activation can take longer than the settle, so the front is
        // watched for as long as a tap waits for it before giving up.
        var waitedUs: UInt32 = 0
        while findProcess()?.isActive != true, waitedUs < EnvConfig.activationConfirmTimeoutUs {
            usleep(EnvConfig.processPollUs)
            waitedUs += EnvConfig.processPollUs
        }
        guard findProcess()?.isActive == true else {
            DebugLog.log("menu", "shortcut not posted: '\(targetName)' did not come to the front")
            return false
        }
        return CGEventInput.postKey(keycode: keycode, flags: .maskCommand)
    }

    /// Determine device orientation from the mirroring window dimensions.
    /// When the iPhone rotates, the mirroring window resizes accordingly.
    func getOrientation() -> DeviceOrientation? {
        getWindowInfo()?.orientation
    }

    /// Activate (bring to front) the iPhone Mirroring app and raise its window.
    /// Uses both NSRunningApplication.activate() and AXUIElement AXRaise (after
    /// un-minimizing) so the window becomes the key window that receives
    /// keyboard input.
    func activate() {
        guard let pid = processID else { return }
        findProcess()?.activate()
        if !probe.raiseMainWindow(pid: pid) {
            DebugLog.log("focus", "AXRaise of the mirroring window was not accepted")
        }
    }

    // MARK: - Private
}
