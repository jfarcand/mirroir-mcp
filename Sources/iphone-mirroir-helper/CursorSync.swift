// ABOUTME: Cursor synchronization helpers for Karabiner HID operations.
// ABOUTME: Eliminates repeated save/warp/nudge/restore boilerplate across command handlers.

import CoreGraphics
import Foundation
import HelperLib

/// Encapsulates the cursor save → disconnect → warp → nudge → action → restore → reconnect
/// sequence shared by all pointing-based command handlers.
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
        karabiner: KarabinerClient,
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
    static func nudgeSync(karabiner: KarabinerClient) {
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
        karabiner: KarabinerClient,
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
}
