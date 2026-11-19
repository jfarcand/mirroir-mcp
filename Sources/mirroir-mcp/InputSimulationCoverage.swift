/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Refuses a HID click when another Mac window covers the point on the target, and waits out a banner over the point.
// ABOUTME: Wires the live window list, display bounds, Notification Center lookup and Accessibility hit test into PointCoverage.

import AppKit
import CoreGraphics
import Foundation
import HelperLib

extension InputSimulation {

    /// Check that a click at window-relative (x, y) would reach the target and
    /// not a window in front of it. Waits while a notification banner is over
    /// the point; a banner elsewhere on the display does not hold the click.
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
                isTransientOverlay: Self.isNotificationCenter,
                ownerAtPoint: { Self.accessibilityOwner(at: point) })
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

    /// The process whose Accessibility element sits at `point` (global screen
    /// coordinates), or nil when Accessibility cannot say. The window server's
    /// hit test skips the clear part of a banner's display-sized window, so
    /// only the banner itself reports Notification Center here.
    private static func accessibilityOwner(at point: CGPoint) -> pid_t? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                               Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private static func isNotificationCenter(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            == EnvConfig.notificationCenterBundleID
    }
}
