// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Window bridge for non-iPhone opaque windows (emulators, VNC, remote desktops).
// ABOUTME: Conforms to WindowBridging only — no menu actions available.

import AppKit
import ApplicationServices
import HelperLib

/// Bridge for any macOS window identified by bundle ID and optional title substring.
/// Uses the same AX/CGWindowList pattern as MirroringBridge but without iPhone-specific
/// state detection (paused/resume) or menu bar actions.
final class GenericWindowBridge: WindowBridging, Sendable {
    let targetName: String
    private let bundleIdentifier: String
    private let processName: String?
    private let windowTitleSubstring: String?

    init(targetName: String, bundleID: String,
         processName: String? = nil,
         windowTitleContains: String? = nil) {
        self.targetName = targetName
        self.bundleIdentifier = bundleID
        self.processName = processName
        self.windowTitleSubstring = windowTitleContains
    }

    func findProcess() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    func getWindowInfo() -> WindowInfo? {
        guard let app = findProcess() else { return nil }
        let pid = app.processIdentifier

        // Try AXMainWindow first (same approach as MirroringBridge)
        let appRef = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appRef, kAXMainWindowAttribute as CFString, &windowValue
        )

        if result == .success,
           let window = windowValue,
           CFGetTypeID(window) == AXUIElementGetTypeID() {
            let axWindow = unsafeDowncast(window, to: AXUIElement.self)
            if let info = windowInfoFromAXElement(axWindow, pid: pid) {
                if matchesWindowTitle(info: info, pid: pid) {
                    return info
                }
            }
        }

        // Fall back to CGWindowList to find matching window
        return findWindowViaCGWindowList(pid: pid)
    }

    func getState() -> WindowState {
        guard findProcess() != nil else { return .notRunning }
        guard getWindowInfo() != nil else { return .noWindow }
        // Generic windows don't have a paused/connected distinction
        return .connected
    }

    func getOrientation() -> DeviceOrientation? {
        guard let info = getWindowInfo() else { return nil }
        return info.size.height > info.size.width ? .portrait : .landscape
    }

    func activate() {
        guard let app = findProcess() else { return }
        app.activate()
    }

    // MARK: - Private

    /// Extract WindowInfo from an AXUIElement window reference.
    private func windowInfoFromAXElement(_ window: AXUIElement, pid: pid_t) -> WindowInfo? {
        var posValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue)
        var position = CGPoint.zero
        if let pv = posValue, CFGetTypeID(pv) == AXValueGetTypeID() {
            AXValueGetValue(unsafeDowncast(pv, to: AXValue.self), .cgPoint, &position)
        }

        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        var size = CGSize.zero
        if let sv = sizeValue, CFGetTypeID(sv) == AXValueGetTypeID() {
            AXValueGetValue(unsafeDowncast(sv, to: AXValue.self), .cgSize, &size)
        }

        guard size.width > 0 && size.height > 0 else { return nil }

        let windowID = findCGWindowID(pid: pid, position: position, size: size)
        return WindowInfo(windowID: windowID ?? 0, position: position, size: size, pid: pid)
    }

    /// Find a window via CGWindowList, optionally filtering by title substring.
    private func findWindowViaCGWindowList(pid: pid_t) -> WindowInfo? {
        let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for entry in windowList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }

            // Filter by title substring if configured
            if let substring = windowTitleSubstring {
                let title = entry[kCGWindowName as String] as? String ?? ""
                guard title.contains(substring) else { continue }
            }

            let wx = (bounds["X"] as? CGFloat) ?? (bounds["X"] as? Int).map { CGFloat($0) } ?? 0
            let wy = (bounds["Y"] as? CGFloat) ?? (bounds["Y"] as? Int).map { CGFloat($0) } ?? 0
            let ww = (bounds["Width"] as? CGFloat) ?? (bounds["Width"] as? Int).map { CGFloat($0) } ?? 0
            let wh = (bounds["Height"] as? CGFloat) ?? (bounds["Height"] as? Int).map { CGFloat($0) } ?? 0

            guard ww > 0 && wh > 0 else { continue }

            return WindowInfo(
                windowID: windowID,
                position: CGPoint(x: wx, y: wy),
                size: CGSize(width: ww, height: wh),
                pid: pid
            )
        }

        return nil
    }

    /// Check if a WindowInfo matches the title filter by looking up the CGWindowList entry.
    private func matchesWindowTitle(info: WindowInfo, pid: pid_t) -> Bool {
        guard let substring = windowTitleSubstring else { return true }

        let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for entry in windowList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any]
            else { continue }

            let wx = (bounds["X"] as? CGFloat) ?? (bounds["X"] as? Int).map { CGFloat($0) } ?? 0
            let wy = (bounds["Y"] as? CGFloat) ?? (bounds["Y"] as? Int).map { CGFloat($0) } ?? 0

            if abs(wx - info.position.x) < 2 && abs(wy - info.position.y) < 2 {
                let title = entry[kCGWindowName as String] as? String ?? ""
                return title.contains(substring)
            }
        }
        return false
    }

    /// Find CGWindowID by matching process ID and geometry.
    private func findCGWindowID(pid: pid_t, position: CGPoint, size: CGSize) -> CGWindowID? {
        let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for entry in windowList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }

            let wx = (bounds["X"] as? CGFloat) ?? (bounds["X"] as? Int).map { CGFloat($0) } ?? 0
            let wy = (bounds["Y"] as? CGFloat) ?? (bounds["Y"] as? Int).map { CGFloat($0) } ?? 0
            let ww = (bounds["Width"] as? CGFloat) ?? (bounds["Width"] as? Int).map { CGFloat($0) } ?? 0
            let wh = (bounds["Height"] as? CGFloat) ?? (bounds["Height"] as? Int).map { CGFloat($0) } ?? 0

            if abs(wx - position.x) < 2 && abs(wy - position.y) < 2
                && abs(ww - size.width) < 2 && abs(wh - size.height) < 2 {
                return windowID
            }
        }
        return nil
    }
}
