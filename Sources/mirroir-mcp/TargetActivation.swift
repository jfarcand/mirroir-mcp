// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The activation sequence that brings a target to the front before input, confirmed against the window server.
// ABOUTME: Requests the front, raises and un-minimizes the window when that is not enough, and refuses instead of posting blind.

import Foundation

/// How bringing the target to the front ended.
enum ActivationOutcome: Equatable, Sendable {
    /// The target was already the active app with the front window; nothing was touched.
    case alreadyFront
    /// The target was brought to the front and the window server confirms it.
    case activated
    /// The target could not be brought to the front; no input may be sent.
    case failed(String)
}

/// The system actions one activation runs, injected so the sequence can be
/// tested without a window server.
struct ActivationSteps {
    /// Whether the target process is running.
    let isRunning: () -> Bool
    /// Whether the target is the active app and owns the front window.
    let isFront: () -> Bool
    /// Ask the system to make the target frontmost (System Events, by PID).
    let requestFront: () -> Void
    /// Un-minimize and raise the target's window, and activate its app.
    let raiseWindow: () -> Void
    /// Wait `microseconds`.
    let wait: (UInt32) -> Void
    /// Name of whatever owns the front window now, for the refusal message.
    let frontOwnerName: () -> String
}

/// Runs the activation sequence: request, confirm, raise, confirm, refuse.
enum TargetActivation {

    /// Bring the target named `targetName` to the front.
    ///
    /// - Parameters:
    ///   - settleUs: wait after each request; a click posted before the
    ///     activation transition finishes is dropped.
    ///   - confirmTimeoutUs: how long to poll for the front after raising.
    ///   - pollUs: interval between those polls.
    static func run(targetName: String, steps: ActivationSteps, settleUs: UInt32,
                    confirmTimeoutUs: UInt32, pollUs: UInt32) -> ActivationOutcome {
        guard steps.isRunning() else {
            return .failed("Target '\(targetName)' is not running, so it cannot receive input.")
        }
        if steps.isFront() { return .alreadyFront }

        steps.requestFront()
        steps.wait(settleUs)
        if steps.isFront() { return .activated }

        // The request alone can leave a minimized window down or a window behind
        // another app's; raise it explicitly, then give the window server time.
        steps.raiseWindow()
        let pollInterval = max(pollUs, 1)
        var waited: UInt32 = 0
        while waited < confirmTimeoutUs {
            steps.wait(pollInterval)
            waited += pollInterval
            if steps.isFront() {
                steps.wait(settleUs)
                return .activated
            }
        }
        return .failed("Could not bring '\(targetName)' to the front: the front window "
            + "belongs to \(steps.frontOwnerName()). No input was sent. Check that the "
            + "mirroring window is on this Space and not minimized, then retry.")
    }
}
