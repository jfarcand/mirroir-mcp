// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Shared utilities for CGWindowList and AXUIElement operations.
// ABOUTME: One typed window-list capture and one matching tolerance for every bridge type.

import AppKit
import ApplicationServices
import CoreGraphics

/// One entry of the window server's window list, parsed once into typed
/// fields so every bridge identifies windows under the same rules.
struct WindowListEntry: Sendable, Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    /// Window title (`kCGWindowName`); nil without Screen Recording permission.
    let name: String?
    let bounds: CGRect
    /// Owning process name (`kCGWindowOwnerName`), when the window server gives one.
    let ownerName: String?
    /// Window layer (`kCGWindowLayer`); 0 is the normal document layer.
    let layer: Int

    init(windowID: CGWindowID, ownerPID: pid_t, name: String?, bounds: CGRect,
         ownerName: String? = nil, layer: Int = 0) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.name = name
        self.bounds = bounds
        self.ownerName = ownerName
        self.layer = layer
    }
}

/// Shared utilities for CGWindowList capture and AXUIElement geometry extraction.
enum WindowListHelper {

    /// Largest difference, in points, between two geometries (origin or
    /// size) that still describe the same window. AX and the window server
    /// round frames differently, so exact equality misses real matches.
    static let geometryMatchTolerance: CGFloat = 4

    /// Capture the window server's window list (excluding desktop elements)
    /// as typed entries. `onScreenOnly` limits it to visible windows, in
    /// front-to-back order. Entries missing an owner, number or bounds are
    /// dropped. Capture once and pass the entries to several queries.
    static func windowEntries(onScreenOnly: Bool = false) -> [WindowListEntry] {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]
        let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.compactMap(entry(from:))
    }

    /// Parse one raw CGWindowList dictionary, or nil when it lacks an owner
    /// PID, a window number or bounds.
    static func entry(from raw: [String: Any]) -> WindowListEntry? {
        guard let ownerPID = raw[kCGWindowOwnerPID as String] as? pid_t,
              let windowID = raw[kCGWindowNumber as String] as? CGWindowID,
              let bounds = raw[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        return WindowListEntry(
            windowID: windowID, ownerPID: ownerPID,
            name: raw[kCGWindowName as String] as? String,
            bounds: parseBounds(bounds),
            ownerName: raw[kCGWindowOwnerName as String] as? String,
            layer: raw[kCGWindowLayer as String] as? Int ?? 0)
    }

    /// PID of the process owning the frontmost normal-layer window, or nil when
    /// no such window is on screen.
    ///
    /// The window server returns the on-screen list in front-to-back order, so
    /// the first entry at layer 0 is the frontmost document window; higher
    /// layers are menus, panels, and system overlays. This asks the window
    /// server directly on every call, which is what makes it usable from a
    /// process that never runs its main run loop — see `RunningAppLocator`.
    static func frontmostWindowOwnerPID() -> pid_t? {
        windowEntries(onScreenOnly: true).first { $0.layer == 0 }?.ownerPID
    }

    /// Whether two geometries are the same within `geometryMatchTolerance`.
    static func matches(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) < geometryMatchTolerance
    }

    /// Find a CGWindowID by matching PID and approximate geometry.
    static func findWindowID(
        pid: pid_t,
        position: CGPoint,
        size: CGSize,
        in windowList: [WindowListEntry]
    ) -> CGWindowID? {
        windowList.first { entry in
            entry.ownerPID == pid
                && matches(entry.bounds.origin.x, position.x)
                && matches(entry.bounds.origin.y, position.y)
                && matches(entry.bounds.width, size.width)
                && matches(entry.bounds.height, size.height)
        }?.windowID
    }

    // MARK: - Private

    /// Parse a CGFloat value from a CGWindowList bounds dictionary.
    /// CGWindowList may return bounds values as CGFloat or Int depending on context.
    private static func parseBoundsValue(_ bounds: [String: Any], key: String) -> CGFloat {
        (bounds[key] as? CGFloat) ?? (bounds[key] as? Int).map { CGFloat($0) } ?? 0
    }

    /// Parse a full CGRect from a CGWindowList bounds dictionary.
    private static func parseBounds(_ bounds: [String: Any]) -> CGRect {
        CGRect(
            x: parseBoundsValue(bounds, key: "X"),
            y: parseBoundsValue(bounds, key: "Y"),
            width: parseBoundsValue(bounds, key: "Width"),
            height: parseBoundsValue(bounds, key: "Height")
        )
    }
}

extension WindowListHelper {

    /// Extract position and size from an AXUIElement window reference.
    static func geometryFromAXElement(_ window: AXUIElement) -> (position: CGPoint, size: CGSize)? {
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
        return (position, size)
    }
}
