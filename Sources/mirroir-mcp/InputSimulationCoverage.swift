// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Refuses a HID click when another Mac window covers the point on the target, and waits out a notification banner.
// ABOUTME: Wires the live window list, display bounds and Notification Center lookup into the PointCoverage verdict.

import AppKit
import CoreGraphics
import Foundation
import HelperLib

extension InputSimulation {

    /// Check that a click at window-relative (x, y) would reach the target and
    /// not a window in front of it. Waits while a notification banner is up.
    /// Returns nil when the point is clear, or the refusal to report.
    ///
    /// A cursor-free post goes to the target process directly, so no window can
    /// intercept it and the check is skipped.
    func checkPointCoverage(tag: String, info: WindowInfo, x: Double, y: Double) -> String? {
        guard cursorFreePID == nil else { return nil }
        let point = CGPoint(x: info.position.x + CGFloat(x), y: info.position.y + CGFloat(y))
        let pollUs = max(EnvConfig.processPollUs, 1)
        var waited: UInt32 = 0
        while true {
            let verdict = PointCoverage.verdict(
                entries: WindowListHelper.windowEntries(onScreenOnly: true),
                targetPID: info.pid, point: point, displays: Self.displayBounds(),
                isTransientOverlay: Self.isNotificationCenter)
            switch verdict {
            case .clear, .targetNotUnderPoint:
                return nil
            case .offDisplay:
                DebugLog.log(tag, "REJECTED: (\(Int(point.x)),\(Int(point.y))) is on no display")
                return "'\(bridge.targetName)' has its window off every display (at "
                    + "\(Int(info.position.x)), \(Int(info.position.y))), so the click would reach "
                    + "nothing. No input was sent. Move the mirroring window back onto a screen, "
                    + "then retry."
            case .covered(let ownerPID, let ownerName):
                let owner = ownerName
                    ?? NSRunningApplication(processIdentifier: ownerPID)?.localizedName
                    ?? "another app"
                DebugLog.log(tag, "REJECTED: \(owner) covers (\(Int(point.x)),\(Int(point.y)))")
                return "A window of \(owner) covers (\(Int(x)), \(Int(y))) on '\(bridge.targetName)', "
                    + "so the click would land on it. No input was sent. Move that window "
                    + "off the mirroring window, then retry."
            case .transientOverlay:
                guard waited < EnvConfig.overlayClearTimeoutUs else {
                    DebugLog.log(tag, "REJECTED: notification overlay did not clear")
                    return "A notification is showing over '\(bridge.targetName)' and did not "
                        + "clear, so the click could land on it. No input was sent. Dismiss "
                        + "the notification on the Mac, then retry."
                }
                usleep(pollUs)
                waited += pollUs
            }
        }
    }

    /// Bounds of every active display, in global screen coordinates.
    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private static func isNotificationCenter(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            == EnvConfig.notificationCenterBundleID
    }
}
