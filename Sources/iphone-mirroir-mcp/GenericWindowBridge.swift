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
        return findWindowViaCGWindowList(pid: nil)
    }

    func getState() -> WindowState {
        if getWindowInfo() != nil { return .connected }
        // Distinguish "not running" from "no window" by checking process existence
        if findProcess() != nil { return .noWindow }
        // Check CGWindowList as final fallback for unbundled processes
        if findWindowViaCGWindowList(pid: nil) != nil { return .connected }
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
    private func getWindowInfoForPID(_ pid: pid_t) -> WindowInfo? {
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

        return findWindowViaCGWindowList(pid: pid)
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

    /// Find a window via CGWindowList. When pid is provided, filters by PID.
    /// When pid is nil, matches by process name and/or window title substring,
    /// which handles unbundled processes (e.g. QEMU).
    private func findWindowViaCGWindowList(pid: pid_t?) -> WindowInfo? {
        let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

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

            let wx = (bounds["X"] as? CGFloat) ?? (bounds["X"] as? Int).map { CGFloat($0) } ?? 0
            let wy = (bounds["Y"] as? CGFloat) ?? (bounds["Y"] as? Int).map { CGFloat($0) } ?? 0
            let ww = (bounds["Width"] as? CGFloat) ?? (bounds["Width"] as? Int).map { CGFloat($0) } ?? 0
            let wh = (bounds["Height"] as? CGFloat) ?? (bounds["Height"] as? Int).map { CGFloat($0) } ?? 0

            guard ww > 0 && wh > 0 else { continue }

            return WindowInfo(
                windowID: windowID,
                position: CGPoint(x: wx, y: wy),
                size: CGSize(width: ww, height: wh),
                pid: ownerPID
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
