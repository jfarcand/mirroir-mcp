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
// ABOUTME: Regression test for issue #34 — the bridge must follow a target that restarts.
// ABOUTME: Drives the restart without a run loop trip, the state the stdio server lives in.

import AppKit
import XCTest
@testable import mirroir_mcp

/// A device respring restarts the mirrored app under a new PID. The MCP server
/// blocks in `readLine()` for its entire lifetime and so never takes the run
/// loop trip that refreshes `NSWorkspace`'s process snapshot — which is why
/// every wait here is a bare `usleep` and every liveness poll goes to Launch
/// Services. The bridge must still find the relaunched process. Before the fix
/// it kept querying AX against the dead PID and reported `.noWindow` until the
/// server process itself was restarted.
///
/// Every assertion reads AX and process state only. Screen capture is covered by
/// the other integration tests and would add an unrelated failure mode here.
final class TargetRestartRecoveryTests: XCTestCase {

    private var bridge: MirroringBridge!

    /// How long the relaunched app gets to publish its AX main window.
    private static let stateSettleAttempts = 40
    private static let stateSettleIntervalUs: UInt32 = 250_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        try IntegrationTestHelper.ensureFakeMirroringRunning()
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
    }

    override func tearDownWithError() throws {
        // Leave FakeMirroring running and capturable for the rest of the suite.
        try IntegrationTestHelper.ensureFakeMirroringRunning()
        IntegrationTestHelper.ensureWindowReady(bridge: bridge)
        try super.tearDownWithError()
    }

    func testBridgeFollowsTargetAcrossRestart() throws {
        let original = try XCTUnwrap(bridge.findProcess(), "FakeMirroring should be running")
        let originalPID = original.processIdentifier
        XCTAssertNotEqual(
            bridge.getState(), .noWindow,
            "Baseline: the bridge should see the running target's window")

        // Built before the restart, exactly as the server builds it once at
        // startup: it must resolve the PID it aims events at per call, not keep
        // the one that was current when it was constructed.
        let input = InputSimulation(bridge: bridge)
        XCTAssertEqual(input.targetPID, originalPID, "Baseline: input should target the running app")

        try terminateFakeMirroring(original)

        // A frozen process snapshot still holds the terminated instance here,
        // which makes the bridge report `.noWindow` — "running, but no window" —
        // for a process that no longer exists.
        XCTAssertNil(
            bridge.findProcess(),
            "Bridge resolved a process after the target exited (PID \(originalPID) is dead)")
        XCTAssertEqual(
            bridge.getState(), .notRunning,
            "A terminated target is `.notRunning`, not `.noWindow`")
        XCTAssertNil(
            input.targetPID,
            "Input still had a PID to aim at after the target exited")

        try IntegrationTestHelper.ensureFakeMirroringRunning()

        let relaunchedPID = try XCTUnwrap(
            bridge.findProcess()?.processIdentifier,
            "Bridge did not find the relaunched target — it is still bound to the dead PID")
        XCTAssertNotEqual(
            relaunchedPID, originalPID,
            "Relaunched FakeMirroring should have a new PID")
        XCTAssertEqual(
            input.targetPID, relaunchedPID,
            "Input is still aiming events at the PID that died before the restart")
        XCTAssertNotEqual(
            settledState(), .noWindow,
            "Bridge stayed in `.noWindow` after the target came back — this is the "
                + "state issue #34 could only leave by restarting the server process")
    }

    /// The bridge's state once it stops reporting `.noWindow`, or `.noWindow` if it
    /// never does. Whether the relaunched app settles on `.connected` or `.paused`
    /// depends on whether it wins activation, which is not what this test is about;
    /// `.noWindow` is the stuck state the fix has to eliminate.
    private func settledState() -> WindowState {
        var state = bridge.getState()
        for _ in 0..<Self.stateSettleAttempts where state == .noWindow {
            bridge.activate()
            usleep(Self.stateSettleIntervalUs)
            state = bridge.getState()
        }
        return state
    }

    /// Quit FakeMirroring and wait for the process to actually exit, polling live
    /// Launch Services state rather than the run-loop-backed snapshot.
    private func terminateFakeMirroring(_ app: NSRunningApplication) throws {
        app.terminate()
        for attempt in 0..<20 {
            usleep(250_000)
            if NSRunningApplication.runningApplications(
                withBundleIdentifier: IntegrationTestHelper.fakeBundleID).isEmpty {
                return
            }
            if attempt == 9 { app.forceTerminate() }
        }
        throw IntegrationTestError.fakeMirroringTerminateFailed
    }
}
