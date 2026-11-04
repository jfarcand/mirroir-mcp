// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Decides from the window server's list whether another window sits over a screen point on the target.
// ABOUTME: Ignores display-sized system overlays, flags a transient banner overlay, and names any window that covers the point.

import CoreGraphics
import Foundation

/// Who would receive a click at a screen point on the target window.
enum PointCoverageVerdict: Equatable, Sendable {
    /// No window in front of the target's window takes clicks at the point.
    case clear
    /// A transient full-display overlay (a notification banner) is up; it
    /// clears by itself, so the caller waits rather than clicking through it.
    case transientOverlay(ownerPID: pid_t)
    /// Another window sits over the point and would take the click.
    case covered(ownerPID: pid_t, ownerName: String?)
    /// The target has no on-screen window under the point.
    case targetNotUnderPoint
    /// The point is on no active display: the window was moved off every
    /// screen, so a click there reaches nothing.
    case offDisplay
}

/// Pure occlusion check over on-screen window entries in front-to-back order.
enum PointCoverage {

    /// Judge a click at `point` (screen coordinates) meant for `targetPID`.
    ///
    /// - Parameters:
    ///   - entries: on-screen windows, front to back
    ///     (`WindowListHelper.windowEntries(onScreenOnly: true)`).
    ///   - displays: bounds of every active display. A point on none of them
    ///     is off-screen. A window exactly one
    ///     display's size above layer 0 is a system overlay (the Dock draws its
    ///     bar in one, always present), not a window that takes the click.
    ///   - isTransientOverlay: whether a display-sized overlay's owner shows
    ///     transient content (notification banners), which is waited out.
    static func verdict(entries: [WindowListEntry], targetPID: pid_t, point: CGPoint,
                        displays: [CGRect],
                        isTransientOverlay: (pid_t) -> Bool) -> PointCoverageVerdict {
        // An empty display list is a failed read, not proof the point is off-screen.
        if !displays.isEmpty && !displays.contains(where: { $0.contains(point) }) {
            return .offDisplay
        }
        guard let targetIndex = entries.firstIndex(where: {
            $0.ownerPID == targetPID && $0.layer >= 0 && $0.bounds.contains(point)
        }) else { return .targetNotUnderPoint }
        // Only windows stacked in front of the target's own window can take its click.
        for entry in entries[..<targetIndex] where entry.layer >= 0 && entry.bounds.contains(point) {
            if entry.layer > 0 && isDisplaySized(entry.bounds, displays: displays) {
                if isTransientOverlay(entry.ownerPID) {
                    return .transientOverlay(ownerPID: entry.ownerPID)
                }
                continue
            }
            return .covered(ownerPID: entry.ownerPID, ownerName: entry.ownerName)
        }
        return .clear
    }

    /// Whether `bounds` matches one display's frame within the window-matching tolerance.
    static func isDisplaySized(_ bounds: CGRect, displays: [CGRect]) -> Bool {
        displays.contains { display in
            WindowListHelper.matches(bounds.origin.x, display.origin.x)
                && WindowListHelper.matches(bounds.origin.y, display.origin.y)
                && WindowListHelper.matches(bounds.width, display.width)
                && WindowListHelper.matches(bounds.height, display.height)
        }
    }
}
