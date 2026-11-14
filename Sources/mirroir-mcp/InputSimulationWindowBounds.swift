// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Bounds checks for pointing input: a point must fall inside the target window it is sent to.
// ABOUTME: A point outside the first read is checked against two agreeing fresh reads, so a window caught mid-animation is not taken for its size.

import CoreGraphics
import Foundation
import HelperLib

extension InputSimulation {

    /// Validate that coordinates fall within the iPhone Mirroring window bounds.
    /// Returns nil if valid, or a descriptive error message if out of bounds.
    func validateBounds(x: Double, y: Double, info: WindowInfo, tag: String) -> String? {
        let w = Double(info.size.width)
        let h = Double(info.size.height)
        // Written as a refusal of anything not inside, so a value that is not
        // a number at all is refused too; and printed without converting to
        // Int, which traps on a value no integer holds.
        if !(x >= 0 && x <= w && y >= 0 && y <= h) {
            let whole = ScreenshotGeometry.whole
            let msg = "Coordinates (\(whole(x)), \(whole(y))) are outside the '\(bridge.targetName)' window (\(whole(w))x\(whole(h))). x must be 0-\(whole(w)), y must be 0-\(whole(h))."
            DebugLog.log(tag, "REJECTED: \(msg)")
            return msg
        }
        return nil
    }

    /// The window every point in `points` falls inside: `info` when they all
    /// fit it, otherwise the window as two fresh reads, each taken after
    /// `windowGeometryRecheckUs`, agree it stands.
    ///
    /// Mission Control, a hot corner or a window move shows the window at a
    /// passing size (a scaled thumbnail) for a moment, and a read taken then
    /// would refuse a point that fits the real window. One fresh read is not
    /// enough to trust either: it may be another passing frame of the same
    /// animation. When the two fresh reads agree on position and size, the
    /// call goes ahead with that window if every point fits it, or is refused
    /// for the coordinates if not. When they disagree, the window is still
    /// moving, and the refusal says so rather than blaming the coordinates.
    /// Nothing is sent on a refusal.
    func windowContaining(
        points: [CGPoint], info: WindowInfo, tag: String
    ) -> (info: WindowInfo?, error: String?) {
        guard let firstError = outOfBounds(points, info: info, tag: tag) else {
            return (info, nil)
        }
        usleep(EnvConfig.windowGeometryRecheckUs)
        guard let settling = bridge.getWindowInfo() else { return (nil, firstError) }
        usleep(EnvConfig.windowGeometryRecheckUs)
        guard let fresh = bridge.getWindowInfo() else { return (nil, firstError) }

        guard settling.size != fresh.size || settling.position != fresh.position else {
            if let freshError = outOfBounds(points, info: fresh, tag: tag) {
                return (nil, freshError)
            }
            DebugLog.log(tag, "window re-read: \(Int(info.size.width))x\(Int(info.size.height)) "
                + "was a passing size, now \(Int(fresh.size.width))x\(Int(fresh.size.height))")
            return (fresh, nil)
        }
        let whole = ScreenshotGeometry.whole
        let size = { (window: WindowInfo) in
            "\(whole(Double(window.size.width)))x\(whole(Double(window.size.height)))"
        }
        let message = "The '\(bridge.targetName)' window read \(size(info)), then \(size(settling)), "
            + "then \(size(fresh)): it is being moved or resized "
            + "(Mission Control, a hot corner or a window drag). Nothing was sent; "
            + "retry once the window has settled."
        DebugLog.log(tag, "REJECTED: \(message)")
        return (nil, message)
    }

    /// `windowContaining(points:info:tag:)` for one point.
    func windowContaining(
        x: Double, y: Double, info: WindowInfo, tag: String
    ) -> (info: WindowInfo?, error: String?) {
        windowContaining(points: [CGPoint(x: x, y: y)], info: info, tag: tag)
    }

    /// The refusal for the first of `points` outside `info`, or nil when all fit.
    private func outOfBounds(_ points: [CGPoint], info: WindowInfo, tag: String) -> String? {
        for point in points {
            if let error = validateBounds(x: Double(point.x), y: Double(point.y), info: info, tag: tag) {
                return error
            }
        }
        return nil
    }
}
