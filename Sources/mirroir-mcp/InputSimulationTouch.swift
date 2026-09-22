// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Persistent single-contact touch (begin/move/end/cancel) for InputSimulation.
// ABOUTME: Resolves the window and bounds, then hands the held contact to the shared TouchSession.

import CoreGraphics
import Foundation

extension InputSimulation {

    /// Drive the persistent touch contact. `begin` goes through the pointing
    /// preamble (connected state, window, bounds, focus); `move` re-reads the
    /// window's live frame and is checked and placed against it (the session
    /// releases the contact when the window changed size or is gone); `end`
    /// and `cancel` need no target at all, so a contact can always be released.
    func touch(_ command: TouchCommand) -> Result<TouchOutcome, TouchSessionError> {
        switch command {
        case .begin(let x, let y):
            return beginTouch(x: x, y: y)
        case .move(let x, let y, let durationMs):
            return moveTouch(x: x, y: y, durationMs: durationMs)
        case .end:
            return touchSession.end()
        case .cancel:
            return touchSession.cancel()
        }
    }

    private func beginTouch(x: Double, y: Double) -> Result<TouchOutcome, TouchSessionError> {
        if let held = touchSession.heldPosition {
            return .failure(.alreadyHeld(at: held.windowPoint))
        }
        let prep = preparePointingInput(tag: "touch", x: x, y: y)
        guard let info = prep.info else {
            return .failure(.rejected(prep.error ?? "Unknown error"))
        }
        DebugLog.log("touch", "begin relative=(\(x),\(y)) window=(\(Int(info.position.x)),\(Int(info.position.y)))")
        return touchSession.begin(at: CGPoint(x: x, y: y), window: info,
                                  targetPID: cursorFreePID, restorePoint: saveCursor())
    }

    private func moveTouch(x: Double, y: Double,
                           durationMs: Int) -> Result<TouchOutcome, TouchSessionError> {
        let liveWindow = bridge.getWindowInfo()
        // Bounds are checked only against a frame the contact can still use;
        // a changed or missing window is the session's to release and report.
        if let liveWindow, let held = touchSession.heldPosition,
           TouchSession.sameSize(liveWindow, held.window),
           let boundsError = validateBounds(x: x, y: y, info: liveWindow, tag: "touch") {
            return .failure(.rejected(boundsError))
        }
        return touchSession.move(to: CGPoint(x: x, y: y), durationMs: durationMs,
                                 liveWindow: liveWindow)
    }
}
