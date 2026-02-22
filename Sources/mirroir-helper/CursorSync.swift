// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Cursor synchronization helpers for Karabiner HID operations.
// ABOUTME: Eliminates repeated save/warp/nudge/restore boilerplate across command handlers.

import CoreGraphics
import Foundation
import HelperLib

/// Encapsulates the cursor save → disconnect → warp → nudge → action → restore → reconnect
/// sequence shared by all pointing-based command handlers.
///
/// SAFETY: Static methods mutate global cursor state (CGWarp, CGAssociate).
/// The daemon processes one command at a time (synchronous handleClient loop),
/// so no concurrent cursor operations occur.
enum CursorSync {

    /// Execute `body` with the system cursor warped to `target` and Karabiner's
    /// virtual pointing device synced to that location. Physical mouse movement
    /// is disabled for the duration to prevent interference.
    ///
    /// Flow:
    /// 1. Save current cursor position
    /// 2. Disconnect physical mouse (CGAssociateMouseAndMouseCursorPosition)
    /// 3. Warp system cursor to `target`
    /// 4. Karabiner nudge (right +1, back −1) to sync virtual device
    /// 5. Execute `body`
    /// 6. Restore cursor to saved position
    /// 7. Reconnect physical mouse
    static func withCursorSynced(
        at target: CGPoint,
        karabiner: any KarabinerProviding,
        body: () -> Void
    ) {
        let savedPosition: CGPoint
        if let event = CGEvent(source: nil) {
            savedPosition = event.location
        } else {
            logHelper("CursorSync: CGEvent(source: nil) returned nil, cursor restore will use origin")
            savedPosition = .zero
        }

        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        CGWarpMouseCursorPosition(target)
        usleep(EnvConfig.cursorSettleUs)

        nudgeSync(karabiner: karabiner)

        body()

        CGWarpMouseCursorPosition(savedPosition)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }

    /// Send a small Karabiner nudge (right then back) to synchronize the virtual
    /// pointing device with the warped system cursor position.
    static func nudgeSync(karabiner: any KarabinerProviding) {
        var nudgeRight = PointingInput()
        nudgeRight.x = 1
        karabiner.postPointingReport(nudgeRight)
        usleep(EnvConfig.nudgeSettleUs)

        var nudgeBack = PointingInput()
        nudgeBack.x = -1
        karabiner.postPointingReport(nudgeBack)
        usleep(EnvConfig.cursorSettleUs)
    }

    /// Perform a button down + hold + up sequence via Karabiner pointing reports.
    static func clickButton(
        karabiner: any KarabinerProviding,
        holdDuration: UInt32
    ) {
        var down = PointingInput()
        down.buttons = 0x01
        karabiner.postPointingReport(down)
        usleep(holdDuration)

        var up = PointingInput()
        up.buttons = 0x00
        karabiner.postPointingReport(up)
        usleep(EnvConfig.cursorSettleUs)
    }

    /// Perform an interpolated button-down → movement → button-up gesture.
    ///
    /// Used by drag (click-drag with initial hold for iOS drag recognition).
    /// Swipe uses scroll wheel events instead (see `handleSwipe`).
    /// The `initialHoldUs` parameter controls the hold after button-down
    /// before movement begins.
    ///
    /// - Parameters:
    ///   - from: Start point (screen-absolute).
    ///   - to: End point (screen-absolute).
    ///   - steps: Number of interpolation steps.
    ///   - moveDurationMs: Time in milliseconds for the movement phase.
    ///   - initialHoldUs: Microseconds to hold after button-down before moving.
    ///   - karabiner: Karabiner HID provider.
    static func interpolatedGesture(
        from: CGPoint,
        to: CGPoint,
        steps: Int,
        moveDurationMs: Int,
        initialHoldUs: UInt32,
        karabiner: any KarabinerProviding
    ) {
        let totalDx = to.x - from.x
        let totalDy = to.y - from.y
        let stepDelayUs = UInt32(max(moveDurationMs, 1) * 1000 / steps)

        // Button down
        var down = PointingInput()
        down.buttons = 0x01
        karabiner.postPointingReport(down)

        if initialHoldUs > 0 {
            usleep(initialHoldUs)
        }

        // Interpolated movement
        for i in 1...steps {
            let progress = Double(i) / Double(steps)
            let targetX = from.x + totalDx * progress
            let targetY = from.y + totalDy * progress

            CGWarpMouseCursorPosition(CGPoint(x: targetX, y: targetY))

            let dx = Int8(clamping: Int(totalDx / Double(steps)))
            let dy = Int8(clamping: Int(totalDy / Double(steps)))
            var move = PointingInput()
            move.buttons = 0x01
            move.x = dx
            move.y = dy
            karabiner.postPointingReport(move)
            usleep(stepDelayUs)
        }

        // Button up
        var up = PointingInput()
        up.buttons = 0x00
        karabiner.postPointingReport(up)
        usleep(EnvConfig.cursorSettleUs)
    }
}
