// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Swipe for InputSimulation: to the target's window when it can be addressed, otherwise through the HID path.
// ABOUTME: A window-addressed swipe moves neither the pointer nor the front app, even with the mirror fully covered.

import CoreGraphics
import Foundation
import HelperLib

extension InputSimulation {

    /// Swipe from one point to another relative to the target window.
    /// Returns nil on success, or an error message on failure.
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int = 300, cursorMode override: CursorMode? = nil) -> String? {
        let handback = beginFrontHandback()
        defer { handback.finish(targetPID: targetPID) }
        let prep = preparePointingInput(tag: "swipe", x: fromX, y: fromY,
                                        byWindow: windowPoster?.canStampEvents == true)
        guard var info = prep.info else { return prep.error ?? "Unknown error" }

        if let boundsError = validateBounds(x: toX, y: toY, info: info, tag: "swipe") {
            return boundsError
        }

        if let poster = prep.windowPoster {
            return swipeByWindow(poster, in: info, fromX: fromX, fromY: fromY,
                                 toX: toX, toY: toY, durationMs: durationMs)
        }

        // After a focus switch, the window is frontmost but not the "key window"
        // for scroll input. Re-query window info AFTER activation to get fresh
        // coordinates, then warp the cursor into the content area. The cursor
        // warp + MayBegin priming in CGEventInput.swipe() engages the scroll
        // subsystem. No click needed — a click risks hitting the title bar or
        // triggering an unwanted iOS action.
        if prep.focusChanged {
            usleep(EnvConfig.spaceSwitchSettleUs)
            if let freshInfo = bridge.getWindowInfo() {
                info = freshInfo
                DebugLog.log("swipe", "re-queried window after focus change: (\(Int(info.position.x)),\(Int(info.position.y)))")
            }
        }

        let saved = saveCursor(mode: override)
        defer { restoreCursor(saved) }

        let startX = Double(info.position.x) + fromX
        let startY = Double(info.position.y) + fromY
        let endX = Double(info.position.x) + toX
        let endY = Double(info.position.y) + toY

        DebugLog.log("swipe", "from=(\(fromX),\(fromY))->(\(toX),\(toY)) screen=(\(Int(startX)),\(Int(startY)))->(\(Int(endX)),\(Int(endY))) duration=\(durationMs)ms")

        let result = CGEventInput.swipe(
            from: CGPoint(x: startX, y: startY),
            to: CGPoint(x: endX, y: endY),
            durationMs: durationMs,
            targetPID: cursorFreePID
        )
        DebugLog.log("swipe", "CGEvent=\(result ? "OK" : "FAILED")")
        guard result else { return "CGEvent swipe failed" }
        return checkLivenessAfter(tag: "swipe", action: "The swipe")
    }

    /// Send the swipe's scroll events to the window's process, each addressed to
    /// the window at the gesture's midpoint, after one key-focus record.
    private func swipeByWindow(_ poster: any WindowEventPosting, in info: WindowInfo,
                               fromX: Double, fromY: Double, toX: Double, toY: Double,
                               durationMs: Int) -> String? {
        guard poster.focusKeys(in: info) else {
            DebugLog.log("swipe", "REJECTED: key focus record not posted")
            return "Could not give '\(bridge.targetName)' input focus. No swipe was sent."
        }
        let midpoint = CGPoint(x: (fromX + toX) / 2, y: (fromY + toY) / 2)
        let screen = { (x: Double, y: Double) in
            CGPoint(x: Double(info.position.x) + x, y: Double(info.position.y) + y)
        }
        DebugLog.log("swipe", "from=(\(fromX),\(fromY))->(\(toX),\(toY)) window \(info.windowID) duration=\(durationMs)ms; front app untouched")
        let result = CGEventInput.swipe(
            from: screen(fromX, fromY), to: screen(toX, toY), durationMs: durationMs,
            targetPID: info.pid,
            stamp: { poster.stamp($0, at: midpoint, in: info) })
        DebugLog.log("swipe", "window events=\(result ? "OK" : "FAILED")")
        guard result else { return "Window swipe failed" }
        return checkLivenessAfter(tag: "swipe", action: "The swipe")
    }
}
