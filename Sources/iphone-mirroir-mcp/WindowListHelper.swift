// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Shared utilities for CGWindowList and AXUIElement operations.
// ABOUTME: Eliminates bounds-parsing and window-ID lookup duplication across bridge types.

import AppKit
import ApplicationServices
import CoreGraphics

/// Shared utilities for CGWindowList parsing and AXUIElement geometry extraction.
enum WindowListHelper {

    /// A raw CGWindowList snapshot. Capture once and pass to multiple query methods
    /// to avoid redundant system calls.
    typealias WindowSnapshot = [[String: Any]]

    /// Capture a snapshot of the full CGWindowList (excluding desktop elements).
    static func captureWindowList() -> WindowSnapshot {
        CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? WindowSnapshot ?? []
    }

    /// Parse a CGFloat value from a CGWindowList bounds dictionary.
    /// CGWindowList may return bounds values as CGFloat or Int depending on context.
    static func parseBoundsValue(_ bounds: [String: Any], key: String) -> CGFloat {
        (bounds[key] as? CGFloat) ?? (bounds[key] as? Int).map { CGFloat($0) } ?? 0
    }

    /// Parse a full CGRect from a CGWindowList bounds dictionary.
    static func parseBounds(_ bounds: [String: Any]) -> CGRect {
        CGRect(
            x: parseBoundsValue(bounds, key: "X"),
            y: parseBoundsValue(bounds, key: "Y"),
            width: parseBoundsValue(bounds, key: "Width"),
            height: parseBoundsValue(bounds, key: "Height")
        )
    }

    /// Find a CGWindowID by matching PID and approximate geometry against a window snapshot.
    static func findWindowID(
        pid: pid_t,
        position: CGPoint,
        size: CGSize,
        in windowList: WindowSnapshot
    ) -> CGWindowID? {
        for entry in windowList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }

            let rect = parseBounds(bounds)

            if abs(rect.origin.x - position.x) < 2
                && abs(rect.origin.y - position.y) < 2
                && abs(rect.width - size.width) < 2
                && abs(rect.height - size.height) < 2 {
                return windowID
            }
        }
        return nil
    }

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
