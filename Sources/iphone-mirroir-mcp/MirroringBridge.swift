// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Bridge to the macOS iPhone Mirroring app (com.apple.ScreenContinuity).
// ABOUTME: Uses AXUIElement APIs to find the window, detect state, and trigger menu actions.

import AppKit
import ApplicationServices

/// Device orientation based on mirroring window dimensions.
enum DeviceOrientation: String, Sendable {
    case portrait
    case landscape
}

/// Connection state of the iPhone Mirroring session.
enum MirroringState: Sendable {
    case connected
    case paused
    case notRunning
    case noWindow
}

/// Information about the mirroring window position and size.
struct WindowInfo: Sendable {
    let windowID: CGWindowID
    let position: CGPoint
    let size: CGSize
    let pid: pid_t
}

/// Bridge to interact with the iPhone Mirroring app via macOS accessibility APIs.
/// The iPhone Mirroring window is special — it does not appear in AXWindows
/// but is accessible via AXMainWindow/AXFocusedWindow.
final class MirroringBridge: Sendable {
    private let bundleIdentifier = "com.apple.ScreenContinuity"

    /// Find the iPhone Mirroring process.
    func findProcess() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    /// Get the AXUIElement for the main mirroring window.
    func getMainWindow() -> (AXUIElement, pid_t)? {
        guard let app = findProcess() else { return nil }
        let pid = app.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)

        var windowValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appRef, kAXMainWindowAttribute as CFString, &windowValue
        )
        guard result == .success,
              let window = windowValue,
              CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        // Safe cast: CFTypeID check above confirms the type
        let axWindow = unsafeBitCast(window, to: AXUIElement.self)
        return (axWindow, pid)
    }

    /// Get the window info including CGWindowID for screenshots.
    func getWindowInfo() -> WindowInfo? {
        guard let (window, pid) = getMainWindow() else { return nil }

        // Get position
        var posValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue)
        var position = CGPoint.zero
        if let pv = posValue, CFGetTypeID(pv) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(pv, to: AXValue.self), .cgPoint, &position)
        }

        // Get size
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        var size = CGSize.zero
        if let sv = sizeValue, CFGetTypeID(sv) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(sv, to: AXValue.self), .cgSize, &size)
        }

        // Find CGWindowID by matching against CGWindowListCopyWindowInfo
        let windowID = findCGWindowID(pid: pid, position: position, size: size)

        return WindowInfo(
            windowID: windowID ?? 0,
            position: position,
            size: size,
            pid: pid
        )
    }

    /// Detect the current mirroring connection state.
    func getState() -> MirroringState {
        guard findProcess() != nil else { return .notRunning }
        guard let (window, _) = getMainWindow() else { return .noWindow }

        // Check children of the window's hosting view
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
        guard let kids = children as? [AXUIElement], let hostingView = kids.first else {
            return .noWindow
        }

        // Check hosting view's children
        var hostChildren: CFTypeRef?
        AXUIElementCopyAttributeValue(
            hostingView, kAXChildrenAttribute as CFString, &hostChildren
        )
        if let hostKids = hostChildren as? [AXUIElement], !hostKids.isEmpty {
            // Has children = showing the paused/disconnected UI
            return .paused
        }

        // No children = active mirroring (opaque video surface)
        return .connected
    }

    /// Press the Resume button when in paused state.
    func pressResume() -> Bool {
        guard let (window, _) = getMainWindow() else { return false }

        // Navigate: window > group (hosting view) > button
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
        guard let kids = children as? [AXUIElement], let hostingView = kids.first else {
            return false
        }

        var hostChildren: CFTypeRef?
        AXUIElementCopyAttributeValue(
            hostingView, kAXChildrenAttribute as CFString, &hostChildren
        )
        guard let hostKids = hostChildren as? [AXUIElement] else { return false }

        for kid in hostKids {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(kid, kAXRoleAttribute as CFString, &role)
            if let r = role as? String, r == kAXButtonRole as String {
                let pressResult = AXUIElementPerformAction(kid, kAXPressAction as CFString)
                return pressResult == .success
            }
        }
        return false
    }

    /// Trigger a menu bar action (e.g., View > Home Screen).
    func triggerMenuAction(menu menuName: String, item itemName: String) -> Bool {
        guard let app = findProcess() else { return false }
        let pid = app.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)

        // Get menu bar
        var menuBarValue: CFTypeRef?
        let menuBarResult = AXUIElementCopyAttributeValue(
            appRef, kAXMenuBarAttribute as CFString, &menuBarValue
        )
        guard menuBarResult == .success,
              let menuBarRef = menuBarValue,
              CFGetTypeID(menuBarRef) == AXUIElementGetTypeID()
        else { return false }
        let menuBar = unsafeBitCast(menuBarRef, to: AXUIElement.self)

        // Find the target menu
        var menuBarChildren: CFTypeRef?
        AXUIElementCopyAttributeValue(
            menuBar, kAXChildrenAttribute as CFString, &menuBarChildren
        )
        guard let menuBarItems = menuBarChildren as? [AXUIElement] else { return false }

        for menuBarItem in menuBarItems {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(menuBarItem, kAXTitleAttribute as CFString, &title)
            guard let t = title as? String, t == menuName else { continue }

            // Open the menu
            var submenuValue: CFTypeRef?
            AXUIElementCopyAttributeValue(
                menuBarItem, kAXChildrenAttribute as CFString, &submenuValue
            )
            guard let submenus = submenuValue as? [AXUIElement],
                  let submenu = submenus.first
            else { continue }

            // Find the menu item
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

    /// Determine device orientation from the mirroring window dimensions.
    /// When the iPhone rotates, the mirroring window resizes accordingly.
    func getOrientation() -> DeviceOrientation? {
        guard let info = getWindowInfo() else { return nil }
        return info.size.height > info.size.width ? .portrait : .landscape
    }

    /// Activate (bring to front) the iPhone Mirroring app and raise its window.
    /// Uses both NSRunningApplication.activate() and AXUIElement AXRaise to
    /// ensure the window becomes the key window that receives keyboard input.
    func activate() {
        findProcess()?.activate()
    }

    // MARK: - Private

    /// Find the CGWindowID by matching process ID and window geometry.
    private func findCGWindowID(pid: pid_t, position: CGPoint, size: CGSize) -> CGWindowID? {
        // Use .optionAll because iPhone Mirroring windows may report isOnScreen=false
        // even when visible. Filter by PID and geometry match instead.
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
            let ww =
                (bounds["Width"] as? CGFloat) ?? (bounds["Width"] as? Int).map { CGFloat($0) } ?? 0
            let wh =
                (bounds["Height"] as? CGFloat) ?? (bounds["Height"] as? Int).map { CGFloat($0) }
                ?? 0

            // Match by approximate position and size
            if abs(wx - position.x) < 2 && abs(wy - position.y) < 2
                && abs(ww - size.width) < 2 && abs(wh - size.height) < 2
            {
                return windowID
            }
        }
        return nil
    }
}
