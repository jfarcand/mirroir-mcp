// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: hold_keys for InputSimulation: refuses while a touch is held or the target lacks focus.
// ABOUTME: Plans the hold with HeldKeysPlanner and plays it through the HeldInputPosting, releasing everything.

import CoreGraphics
import Foundation

extension InputSimulation {

    /// Hold the request's keys (and drag its button, when it has one) for the
    /// request's duration, then release everything. Returns nil on success, or
    /// an error message.
    ///
    /// Refused while a persistent touch is held: a button drag would lift it,
    /// and the refusal is the same one every pointing operation gives. With a
    /// drag, the pointing preamble checks state, window and both endpoints;
    /// without one, the keyboard preamble checks state and focuses the target.
    func holdKeys(_ request: HeldKeysRequest) -> String? {
        let tool = HeldKeysRequest.toolName
        if let refusal = touchSession.heldRefusal(tool: tool) {
            DebugLog.log(tool, "REJECTED: touch held")
            return refusal
        }

        var dragPath: (from: CGPoint, to: CGPoint)?
        if let drag = request.drag {
            let prep = preparePointingInput(tag: tool, x: drag.fromX, y: drag.fromY)
            guard let info = prep.info else { return prep.error ?? "Unknown error" }
            if let boundsError = validateBounds(x: drag.toX, y: drag.toY, info: info, tag: tool) {
                return boundsError
            }
            dragPath = (CGPoint(x: info.position.x + CGFloat(drag.fromX),
                                y: info.position.y + CGFloat(drag.fromY)),
                        CGPoint(x: info.position.x + CGFloat(drag.toX),
                                y: info.position.y + CGFloat(drag.toY)))
        } else {
            if let keyboardError = prepareKeyboardInput(tag: tool) { return keyboardError }
            ensureTargetFrontmost()
        }
        // Keyboard events reach whichever Mac app has focus: activation can
        // fail silently (another Space, no System Events permission), and a
        // held modifier with a repeating key would drive that other app.
        guard bridge.isFrontmost() else {
            DebugLog.log(tool, "REJECTED: target not frontmost")
            return "\(tool) refused: '\(bridge.targetName)' is not the frontmost app, so the keys "
                + "would go to another Mac app. Bring the mirroring window to the front and retry."
        }

        let saved = saveCursor()
        defer { restoreCursor(saved) }

        DebugLog.log(tool, "keys=\(request.keys.map(\.name).joined(separator: "+")) "
            + "duration=\(request.durationMs)ms drag=\(request.drag.map { "\($0.button)" } ?? "none")")
        let plan = HeldKeysPlanner.plan(for: request, dragPath: dragPath)
        let outcome = HeldInputPlayback.play(plan, targetPID: cursorFreePID, poster: heldInputPoster,
                                             targetFocused: { bridge.isFrontmost() })
        DebugLog.log(tool, "outcome=\(outcome)")
        switch outcome {
        case .delivered:
            return nil
        case .postFailed:
            return "CGEvent \(tool) failed"
        case .focusLost:
            return "\(tool) stopped early: '\(bridge.targetName)' lost focus during the hold, so "
                + "further keys would have gone to another Mac app. Every key and button was released."
        case .interrupted:
            return "\(tool) stopped early: the server is shutting down. Every key and button was released."
        }
    }
}
