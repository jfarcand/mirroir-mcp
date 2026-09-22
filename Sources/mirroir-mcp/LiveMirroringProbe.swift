// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Live MirroringSystemProbing: Launch Services, Accessibility and CGWindowList read per call.
// ABOUTME: Holds no state, so geometry, state and PID follow rotations, resizes and restarts.

import AppKit
import ApplicationServices
import CoreGraphics

/// Reads the iPhone Mirroring process and window from the live system.
///
/// Nothing is cached: the process comes from Launch Services through
/// `RunningAppLocator` (never NSWorkspace's snapshot, which freezes in the
/// server), and each window read is a fresh AX or window-server query.
struct LiveMirroringProbe: MirroringSystemProbing {

    /// Depth bound for the hosting-view snapshot. The paused overlay's controls
    /// sit a few levels below the hosting view; the live surface has no children.
    static let maxHostingViewDepth = 8

    func processID(bundleID: String) -> pid_t? {
        RunningAppLocator.byBundleID(bundleID)?.processIdentifier
    }

    func mainWindow(pid: pid_t) -> MirroringAXWindow? {
        guard let window = Self.axMainWindow(pid: pid) else { return nil }
        let frame = WindowListHelper.geometryFromAXElement(window).map {
            CGRect(origin: $0.position, size: $0.size)
        }
        let hosting = Self.children(of: window).first.map {
            Self.snapshot($0, depth: 0)
        }
        return MirroringAXWindow(
            title: Self.stringAttribute(window, kAXTitleAttribute),
            frame: frame, hostingView: hosting)
    }

    func windowList() -> [WindowListEntry] {
        WindowListHelper.windowEntries()
    }

    func pressResumeControl(pid: pid_t) -> Bool {
        guard let window = Self.axMainWindow(pid: pid),
              let hostingView = Self.children(of: window).first else { return false }
        for kid in Self.children(of: hostingView)
        where Self.stringAttribute(kid, kAXRoleAttribute) == kAXButtonRole as String {
            let label = Self.label(of: kid)
            guard MirroringWindowResolver.isResumeControl(label: label) else {
                DebugLog.log("resume", "skipping overlay button '\(label ?? "")' — not a resume control")
                continue
            }
            return AXUIElementPerformAction(kid, kAXPressAction as CFString) == .success
        }
        return false
    }

    func dismissControlPoint(pid: pid_t) -> CGPoint? {
        guard let window = Self.axMainWindow(pid: pid),
              let button = Self.dismissButton(under: window, depth: 0),
              let geom = WindowListHelper.geometryFromAXElement(button) else { return nil }
        return CGPoint(x: geom.position.x + geom.size.width / 2,
                       y: geom.position.y + geom.size.height / 2)
    }

    /// The app's AX main window. iPhone Mirroring does not list its window in
    /// `AXWindows`; it is reachable only as `AXMainWindow`.
    static func axMainWindow(pid: pid_t) -> AXUIElement? {
        let appRef = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appRef, kAXMainWindowAttribute as CFString, &windowValue)
        guard result == .success, let window = windowValue,
              CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        // Safe cast: the CFTypeID check above confirms the type.
        return unsafeDowncast(window, to: AXUIElement.self)
    }

    /// Children of an AX element, or empty when it has none.
    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    /// The element's title, or its description when it has no title.
    static func label(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = stringAttribute(element, attribute),
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }
        return nil
    }

    // MARK: - Private

    /// Depth-bounded search for a labeled AXButton that names a known resume
    /// or dismiss action. The connected mirroring surface is opaque with no
    /// AX children, so a button is found only when an interruption overlay shows.
    private static func dismissButton(under element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > maxHostingViewDepth { return nil }
        if stringAttribute(element, kAXRoleAttribute) == kAXButtonRole as String,
           let label = label(of: element),
           MirroringWindowResolver.isResumeControl(label: label) {
            return element
        }
        for kid in children(of: element) {
            if let found = dismissButton(under: kid, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func snapshot(_ element: AXUIElement, depth: Int) -> AXNodeSnapshot {
        let kids = depth < maxHostingViewDepth
            ? children(of: element).map { snapshot($0, depth: depth + 1) }
            : []
        // Static text carries its words in AXValue rather than a title.
        return AXNodeSnapshot(
            role: stringAttribute(element, kAXRoleAttribute),
            label: label(of: element) ?? stringAttribute(element, kAXValueAttribute),
            children: kids)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }
}
