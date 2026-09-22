// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Bridge to the macOS iPhone Mirroring app (com.apple.ScreenContinuity).
// ABOUTME: Uses AXUIElement APIs to find the window, detect state, and trigger menu actions.

import AppKit
import ApplicationServices
import HelperLib

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
enum WindowState: Sendable {
    case connected
    case paused
    case notRunning
    case noWindow
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

    init(targetName: String = "iphone",
         bundleID: String? = nil,
         probe: any MirroringSystemProbing = LiveMirroringProbe()) {
        self.targetName = targetName
        self.bundleIdentifier = bundleID ?? EnvConfig.mirroringBundleID
        self.probe = probe
    }

    /// PID of the iPhone Mirroring process right now, or nil when not running.
    private var processID: pid_t? {
        probe.processID(bundleID: bundleIdentifier)
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
        guard let window = probe.mainWindow(pid: pid) else { return .noWindow }
        return MirroringWindowResolver.state(of: window)
    }

    /// Press the resume control of the paused overlay.
    ///
    /// Presses only a button `MirroringWindowResolver.isResumeControl` accepts:
    /// the overlay's unlabeled resume button or a known resume/dismiss title.
    /// Any other button is left alone — pressing an arbitrary first button can
    /// close the Mirroring window and terminate the app. The lookup and the
    /// press go through `probe`, the same reads `getState` classifies.
    func pressResume() -> Bool {
        guard let pid = processID else { return false }
        return probe.pressResumeControl(pid: pid)
    }

    /// Screen-center of the overlay's *dismiss* button (e.g. the camera dialog's
    /// "OK"), located by title so we don't click a stray titlebar/toolbar control.
    /// See `MenuActionCapable.pausedDismissButtonPoint`.
    func pausedDismissButtonPoint() -> CGPoint? {
        guard let pid = processID else { return nil }
        return probe.dismissControlPoint(pid: pid)
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
        return CGEventInput.postKey(keycode: keycode, flags: .maskCommand)
    }

    /// Determine device orientation from the mirroring window dimensions.
    /// When the iPhone rotates, the mirroring window resizes accordingly.
    func getOrientation() -> DeviceOrientation? {
        getWindowInfo()?.orientation
    }

    /// Activate (bring to front) the iPhone Mirroring app and raise its window.
    /// Uses both NSRunningApplication.activate() and AXUIElement AXRaise to
    /// ensure the window becomes the key window that receives keyboard input.
    func activate() {
        findProcess()?.activate()
    }

    // MARK: - Private
}
