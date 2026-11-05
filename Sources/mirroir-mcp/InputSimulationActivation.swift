// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Brings the input target to the front before a click or keystroke, and confirms it with the window server.
// ABOUTME: Wires the live System Events request, window raise and front check into the TargetActivation sequence.

import AppKit
import Foundation
import HelperLib

extension InputSimulation {

    /// Ensure the target is the active app with the front window, so a click
    /// or keystroke reaches it rather than whatever the user has in front.
    ///
    /// "Front" is read from the window server and the freshly resolved process,
    /// never from `NSWorkspace.frontmostApplication`, which is frozen in a
    /// server that never runs its main run loop (see `RunningAppLocator`).
    ///
    /// When the target is already front, this returns without touching focus:
    /// the System Events `set frontmost` call disturbs event routing for a beat
    /// even when it is a no-op, and a click posted inside that window is
    /// silently dropped (measured against FakeMirroring — the same tap delivers
    /// with no AppleScript, or with AppleScript plus the settle sleep, but never
    /// with AppleScript and no settle).
    ///
    /// The request goes through System Events by PID, which survives a localized
    /// or renamed process and can switch Spaces (NSRunningApplication.activate()
    /// cannot). When the window server does not confirm the front, the window is
    /// un-minimized and raised and the front is polled again; if it still is not
    /// front the outcome is `.failed` and the caller sends nothing.
    func ensureTargetFrontmost() -> ActivationOutcome {
        let bridge = self.bridge
        // An unbundled target (e.g. QEMU) has no NSRunningApplication but still
        // owns a window, so it counts as running; its front is requested
        // through the bridge, since System Events is asked only for a process
        // Launch Services knows.
        let process = bridge.findProcess()
        let running = process != nil || bridge.getWindowInfo() != nil
        let steps = ActivationSteps(
            isRunning: { running },
            isFront: { bridge.isFrontmost() },
            requestFront: {
                if let pid = process?.processIdentifier {
                    Self.requestFrontmost(pid: pid)
                } else {
                    bridge.activate()
                }
            },
            raiseWindow: { bridge.activate() },
            wait: { usleep($0) },
            frontOwnerName: {
                RunningAppLocator.frontmostWindowOwner()?.localizedName ?? "no visible app"
            })
        let outcome = TargetActivation.run(
            targetName: bridge.targetName, steps: steps,
            settleUs: EnvConfig.spaceSwitchSettleUs,
            confirmTimeoutUs: EnvConfig.activationConfirmTimeoutUs,
            pollUs: EnvConfig.processPollUs)
        DebugLog.log("focus", "activation: \(outcome)")
        return outcome
    }

    /// Ask System Events to make the process with `pid` frontmost.
    static func requestFrontmost(pid: pid_t) {
        let script = NSAppleScript(source: """
            tell application "System Events"
                set frontmost of (first process whose unix id is \(pid)) to true
            end tell
            """)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
        if let err = errorInfo {
            DebugLog.log("focus", "System Events request failed: \(err)")
        }
    }
}
