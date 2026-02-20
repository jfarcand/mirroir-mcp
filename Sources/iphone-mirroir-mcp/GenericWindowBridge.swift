// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Window bridge for non-iPhone opaque windows (emulators, VNC, remote desktops).
// ABOUTME: Conforms to WindowBridging only — no menu actions available.

import AppKit
import ApplicationServices
import HelperLib

/// Bridge for any macOS window identified by bundle ID, process name, or window title.
/// Uses the same AX/CGWindowList pattern as MirroringBridge but without iPhone-specific
/// state detection (paused/resume) or menu bar actions.
///
/// Supports apps without bundle identifiers (e.g. QEMU-based Android emulators) by
/// falling back to CGWindowList process name matching when no bundle ID is configured.
final class GenericWindowBridge: WindowBridging, Sendable {
    let targetName: String
    private let bundleIdentifier: String?
    private let processName: String?
    private let windowTitleSubstring: String?

    init(targetName: String, bundleID: String?,
         processName: String? = nil,
         windowTitleContains: String? = nil) {
        self.targetName = targetName
        self.bundleIdentifier = (bundleID?.isEmpty ?? true) ? nil : bundleID
        self.processName = processName
        self.windowTitleSubstring = windowTitleContains
    }

    func findProcess() -> NSRunningApplication? {
        if let bid = bundleIdentifier {
            return NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == bid
            }
        }
        // For apps without bundle IDs (e.g. QEMU), match by localizedName
        if let name = processName {
            return NSWorkspace.shared.runningApplications.first {
                $0.localizedName == name
            }
        }
        return nil
    }

    func getWindowInfo() -> WindowInfo? {
        // Try bundle ID / process name lookup via NSWorkspace first
        if let app = findProcess() {
            let pid = app.processIdentifier
            if let info = getWindowInfoForPID(pid) {
                return info
            }
        }

        // Fall back to CGWindowList scan by process name or window title.
        // This handles apps like QEMU that have no bundle ID and may not
        // appear in NSWorkspace.runningApplications with a matching name.
        return findWindowInList(pid: nil, windowList: WindowListHelper.captureWindowList())
    }

    func getState() -> WindowState {
        if getWindowInfo() != nil { return .connected }
        // Distinguish "not running" from "no window" by checking process existence
        if findProcess() != nil { return .noWindow }
        // Check CGWindowList as final fallback for unbundled processes
        if findWindowInList(pid: nil, windowList: WindowListHelper.captureWindowList()) != nil {
            return .connected
        }
        return .notRunning
    }

    func getOrientation() -> DeviceOrientation? {
        guard let info = getWindowInfo() else { return nil }
        return info.size.height > info.size.width ? .portrait : .landscape
    }

    func activate() {
        guard let app = findProcess() else { return }
        app.activate()
    }

    /// Try AXMainWindow then CGWindowList for a known PID.
    /// Uses a single CGWindowList snapshot for all lookups.
    private func getWindowInfoForPID(_ pid: pid_t) -> WindowInfo? {
        let windowList = WindowListHelper.captureWindowList()

        let appRef = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appRef, kAXMainWindowAttribute as CFString, &windowValue
        )

        if result == .success,
           let window = windowValue,
           CFGetTypeID(window) == AXUIElementGetTypeID() {
            let axWindow = unsafeDowncast(window, to: AXUIElement.self)
            if let geom = WindowListHelper.geometryFromAXElement(axWindow) {
                let windowID = WindowListHelper.findWindowID(
                    pid: pid, position: geom.position, size: geom.size, in: windowList
                )
                if let windowID, windowID != 0,
                   matchesWindowTitle(position: geom.position, pid: pid, in: windowList) {
                    return WindowInfo(
                        windowID: windowID,
                        position: geom.position,
                        size: geom.size,
                        pid: pid
                    )
                }
            }
        }

        // AX path failed or returned windowID=0 (common with Electron apps
        // where AX geometry doesn't match CGWindowList geometry exactly).
        // CGWindowList gives us the real window ID directly.
        return findWindowInList(pid: pid, windowList: windowList)
    }

    // MARK: - Private

    /// Find a window in a pre-captured CGWindowList snapshot.
    /// When pid is provided, filters by PID. When pid is nil, matches by
    /// process name and/or window title substring (handles unbundled processes like QEMU).
    private func findWindowInList(pid: pid_t?,
                                  windowList: WindowListHelper.WindowSnapshot) -> WindowInfo? {
        for entry in windowList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }

            // Match by PID when known
            if let pid = pid, ownerPID != pid { continue }

            // Match by process name when PID is not known
            if pid == nil {
                let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
                if let name = processName {
                    guard ownerName == name else { continue }
                } else if windowTitleSubstring == nil {
                    // No PID, no process name, no title filter — cannot match
                    continue
                }
            }

            // Filter by title substring if configured
            if let substring = windowTitleSubstring {
                let title = entry[kCGWindowName as String] as? String ?? ""
                guard title.contains(substring) else { continue }
            }

            let rect = WindowListHelper.parseBounds(bounds)
            guard rect.width > 0 && rect.height > 0 else { continue }

            return WindowInfo(
                windowID: windowID,
                position: rect.origin,
                size: rect.size,
                pid: ownerPID
            )
        }

        return nil
    }

    /// Check if a window at the given position matches the title filter.
    private func matchesWindowTitle(position: CGPoint, pid: pid_t,
                                    in windowList: WindowListHelper.WindowSnapshot) -> Bool {
        guard let substring = windowTitleSubstring else { return true }

        for entry in windowList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any]
            else { continue }

            let rect = WindowListHelper.parseBounds(bounds)
            if abs(rect.origin.x - position.x) < 2
                && abs(rect.origin.y - position.y) < 2 {
                let title = entry[kCGWindowName as String] as? String ?? ""
                return title.contains(substring)
            }
        }
        return false
    }
}
