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
// ABOUTME: Quits iPhone Mirroring and opens it again, then waits until it is connected (carnet#98).
// ABOUTME: The fix for input that stops landing; it ends the session, so its tool asks consent first.

import Foundation
import HelperLib

/// A target whose app can be quit and opened again by this server.
protocol MirroringRestartable: WindowBridging {
    func restart(timing: MirroringRestart.Timing) -> MirroringRestart.Outcome
}

enum MirroringRestart {
    /// How long each phase may take, and how often it is checked.
    struct Timing: Sendable {
        var quitSeconds: Double = 10
        var connectSeconds: Double = 60
        var pollSeconds: Double = 0.5
        var sleep: @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    }

    enum Outcome: Equatable {
        /// The app was not running: a quit app stays quit, so nothing is opened.
        case notRunning
        /// The quit request could not be sent.
        case quitRefused
        /// The app was still running when the quit time ran out.
        case stillRunning(seconds: Double)
        /// Launch Services refused to open the app again.
        case launchRefused
        /// The app came back and its session is connected.
        case connected(seconds: Double)
        /// The app came back but its session did not connect in time.
        case notConnected(state: WindowState, block: SessionBlock?, seconds: Double)

        var succeeded: Bool {
            if case .connected = self { return true }
            return false
        }

        func message(targetName: String) -> String {
            let whole = { (s: Double) in String(format: "%.0f", s) }
            switch self {
            case .notRunning:
                return "iPhone Mirroring is not running, so it was not restarted. Open it on the Mac, "
                    + "or ask the user to: an app that was quit stays quit."
            case .quitRefused:
                return "iPhone Mirroring did not accept the request to quit. Nothing was restarted."
            case .stillRunning(let seconds):
                return "iPhone Mirroring was asked to quit but still ran after \(whole(seconds)) s. "
                    + "It was not opened again; quit it on the Mac and retry."
            case .launchRefused:
                return "iPhone Mirroring quit, but opening it again was refused. Open it on the Mac."
            case .connected(let seconds):
                return "Restarted iPhone Mirroring: '\(targetName)' is connected again after \(whole(seconds)) s."
            case .notConnected(let state, let block, let seconds):
                var text = "iPhone Mirroring was opened again but is \(state.rawValue), not connected, "
                    + "after \(whole(seconds)) s."
                if let block {
                    text += " The window says: \(block.said). \(block.move.advice)"
                    if block.move.needsUser { text += " " + AgentInstruction.waitForUser }
                }
                return text
            }
        }
    }
}

extension MirroringBridge: MirroringRestartable {
    /// Quit the app, open it again in the background, and wait until it connects.
    /// Only a running app is restarted: one already quit stays quit.
    func restart(timing: MirroringRestart.Timing) -> MirroringRestart.Outcome {
        guard let pid = probe.processID(bundleID: bundleIdentifier) else { return .notRunning }
        guard probe.quit(pid: pid) else { return .quitRefused }
        var waited = 0.0
        while probe.processID(bundleID: bundleIdentifier) == pid {
            guard waited < timing.quitSeconds else { return .stillRunning(seconds: waited) }
            timing.sleep(timing.pollSeconds)
            waited += timing.pollSeconds
        }
        DebugLog.log("restart", "\(bundleIdentifier) quit after \(waited)s; opening it again")
        // This server quit it, so the quit-stays-quit rule of launchInBackground() does not apply.
        guard probe.launchInBackground(bundleID: bundleIdentifier) else { return .launchRefused }
        var connecting = 0.0
        while true {
            let state = getState()
            if state == .connected { return .connected(seconds: waited + connecting) }
            guard connecting < timing.connectSeconds else {
                return .notConnected(state: state, block: sessionBlock(), seconds: waited + connecting)
            }
            timing.sleep(timing.pollSeconds)
            connecting += timing.pollSeconds
        }
    }
}
