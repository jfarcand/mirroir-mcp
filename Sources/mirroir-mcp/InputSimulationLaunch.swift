// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Starts iPhone Mirroring in the background when an input call finds it not running, and waits out "Connecting".
// ABOUTME: The user's front app keeps the focus; a block that needs the user ends the wait and is reported as usual.

import Foundation
import HelperLib

extension InputSimulation {

    /// Launch a target that is not running, without making it active, and
    /// wait for its session to come up. Only a bridge that can launch its
    /// app (iPhone Mirroring) does anything; other targets are started by
    /// the user. Nothing is sent: the caller's connection check then reports
    /// whatever state the launch reached.
    func launchIfNotRunning(tag: String) {
        guard bridge.getState() == .notRunning,
              let launcher = bridge as? MenuActionCapable else { return }
        guard launcher.launchInBackground() else {
            DebugLog.log(tag, "target not running and the background launch was refused")
            return
        }
        DebugLog.log(tag, "target not running — launched in the background")
        waitForConnection(tag: tag)
    }

    /// Wait while the session is starting: the process launching, the window
    /// opening, or the window reading "Connecting to". Returns as soon as the
    /// session is connected, shows a block that waiting does not clear (the
    /// iPhone in use, a Connect button, a Mac prompt), or
    /// `EnvConfig.launchConnectTimeoutUs` passes.
    func waitForConnection(tag: String) {
        let pollUs = max(EnvConfig.launchConnectPollUs, 1)
        var waitedUs: UInt32 = 0
        while waitedUs < EnvConfig.launchConnectTimeoutUs {
            let state = bridge.getState()
            if state == .connected { return }
            if state == .paused,
               (bridge as? MenuActionCapable)?.sessionBlock()?.move != .waitWhileConnecting {
                return
            }
            usleep(pollUs)
            waitedUs += pollUs
        }
        DebugLog.log(tag, "session still starting after \(waitedUs / 1000)ms")
    }
}
