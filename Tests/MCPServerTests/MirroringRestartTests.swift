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
// ABOUTME: Tests for restarting iPhone Mirroring (carnet#98): quit, open again, wait to connect.
// ABOUTME: Drives MirroringBridge through ScriptedMirroringProbe, so no app is ever quit.

import CoreGraphics
import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class MirroringRestartTests: XCTestCase {

    private static let title = "iPhone Mirroring"
    private static let frame = CGRect(x: 1293, y: 120, width: 410, height: 898)

    private let probe = ScriptedMirroringProbe()
    private lazy var bridge = MirroringBridge(bundleID: "com.example.mirroring", probe: probe)
    private let sleepLog = SleepLog()
    private var sleeps: [Double] { sleepLog.values }
    private lazy var timing = MirroringRestart.Timing(
        quitSeconds: 2, connectSeconds: 3, pollSeconds: 0.5,
        sleep: { [sleepLog] in sleepLog.append($0) })

    private func entries(_ pid: pid_t) -> [WindowListEntry] {
        [WindowListEntry(windowID: 11, ownerPID: pid, name: Self.title, bounds: Self.frame)]
    }

    private func connected(_ pid: pid_t) {
        probe.set(pid: pid, axWindow: MirroringAXWindow(
            title: Self.title, frame: Self.frame, hostingView: AXNodeSnapshot(role: "AXGroup")),
            entries: entries(pid))
    }

    private func iPhoneInUse(_ pid: pid_t) {
        probe.set(pid: pid, axWindow: MirroringAXWindow(
            title: Self.title, frame: Self.frame,
            hostingView: AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXStaticText", label: "iPhone in Use"),
                AXNodeSnapshot(role: "AXStaticText", label: "Lock your iPhone to connect."),
                AXNodeSnapshot(role: "AXButton", label: "Try Again"),
            ])), entries: entries(pid))
    }

    func testARunningAppIsQuitOpenedAgainAndConnected() {
        connected(300)
        probe.set(onQuit: { [probe] in probe.set(pid: nil, axWindow: nil, entries: []) })
        probe.set(onLaunch: { [weak self] in self?.connected(301) })

        let outcome = bridge.restart(timing: timing)

        XCTAssertEqual(outcome, .connected(seconds: 0))
        XCTAssertEqual(probe.quitPIDs, [300])
        XCTAssertEqual(probe.launchedBundleIDs, ["com.example.mirroring"],
                       "this server quit it, so it opens it again")
        XCTAssertEqual(bridge.getState(), .connected)
        XCTAssertFalse(bridge.wasQuit)
        XCTAssertEqual(outcome.message(targetName: "iphone"),
                       "Restarted iPhone Mirroring: 'iphone' is connected again after 0 s.")
    }

    func testAnAppThatIsNotRunningIsNeitherQuitNorOpened() {
        let outcome = bridge.restart(timing: timing)
        XCTAssertEqual(outcome, .notRunning)
        XCTAssertTrue(probe.quitPIDs.isEmpty)
        XCTAssertTrue(probe.launchedBundleIDs.isEmpty)
    }

    func testAnAppThatDoesNotQuitIsNotOpenedAgain() {
        connected(300)
        let outcome = bridge.restart(timing: timing)
        XCTAssertEqual(outcome, .stillRunning(seconds: 2))
        XCTAssertTrue(probe.launchedBundleIDs.isEmpty)
        XCTAssertEqual(sleeps, [0.5, 0.5, 0.5, 0.5])
    }

    func testARefusedQuitChangesNothing() {
        connected(300)
        probe.set(quitAccepted: false)
        XCTAssertEqual(bridge.restart(timing: timing), .quitRefused)
        XCTAssertTrue(probe.launchedBundleIDs.isEmpty)
    }

    func testARefusedLaunchIsReported() {
        connected(300)
        probe.set(onQuit: { [probe] in probe.set(pid: nil, axWindow: nil, entries: []) })
        probe.set(launchAccepted: false)
        XCTAssertEqual(bridge.restart(timing: timing), .launchRefused)
    }

    func testAnAppThatOpensButAsksForTheUserSaysWhat() {
        connected(300)
        probe.set(onQuit: { [probe] in probe.set(pid: nil, axWindow: nil, entries: []) })
        probe.set(onLaunch: { [weak self] in self?.iPhoneInUse(301) })

        let outcome = bridge.restart(timing: timing)

        guard case .notConnected(let state, let block, let seconds) = outcome else {
            return XCTFail("got \(outcome)")
        }
        XCTAssertEqual(state, .paused)
        XCTAssertEqual(block?.move, .lockIPhone)
        XCTAssertEqual(seconds, 3)
        let message = outcome.message(targetName: "iphone")
        XCTAssertTrue(message.hasPrefix(
            "iPhone Mirroring was opened again but is paused, not connected, after 3 s. "
            + "The window says: “iPhone in Use” “Lock your iPhone to connect.” [Try Again]."),
            message)
    }
}

/// The sleeps a restart asked for, instead of sleeping.
private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    var values: [Double] { lock.withLock { recorded } }
    func append(_ seconds: Double) { lock.withLock { recorded.append(seconds) } }
}
