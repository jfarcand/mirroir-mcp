// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tunnel lease tests: child lifecycle with real processes, early exits, timeouts, and devicectl JSON parsing.
// ABOUTME: The keep-alive child is a real /bin/sh or /bin/sleep so termination and reaping are exercised for real.

import Foundation
import XCTest
@testable import MirroirCoreDevice

/// Tunnel states in sequence, repeating the last one. A fake because no
/// device with a controllable tunnel exists in the test environment.
final class ScriptedTunnelStates: TunnelStateReading {
    private var states: [String?]
    private(set) var queries: [String] = []

    init(_ states: [String?]) {
        self.states = states
    }

    func tunnelState(ofDevice device: String) throws -> String? {
        queries.append(device)
        return states.count > 1 ? states.removeFirst() : states.first ?? nil
    }
}

final class CoreDeviceTunnelLeaseTests: XCTestCase {
    private let device = "11111111-2222-3333-4444-555555555555"
    private let shortGrace: TimeInterval = 0.5

    private static let sleeper = CoreDeviceTunnelLease.KeepAliveCommand(
        executableURL: URL(fileURLWithPath: "/bin/sleep")) { _ in ["30"] }

    /// A child that writes `json` to its JSON output path and exits with `status`.
    private static func exiting(status: Int32, json: String) -> CoreDeviceTunnelLease.KeepAliveCommand {
        CoreDeviceTunnelLease.KeepAliveCommand(executableURL: URL(fileURLWithPath: "/bin/sh")) { path in
            ["-c", "printf '%s' \"$1\" > \"$0\"; exit \(status)", path, json]
        }
    }

    private func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    func testStartWaitsForConnectedAndStopReapsTheChild() throws {
        let states = ScriptedTunnelStates(["unavailable", "connecting", "connected"])
        let lease = CoreDeviceTunnelLease(device: device, keepAlive: Self.sleeper, tunnelStates: states,
                                          terminationGrace: shortGrace)
        try lease.start(timeout: 10)
        XCTAssertTrue(lease.isHeld)
        XCTAssertEqual(states.queries, [device, device, device])
        let pid = try XCTUnwrap(lease.keepAliveProcessIdentifier)
        XCTAssertTrue(isAlive(pid))

        try lease.start(timeout: 10)
        XCTAssertEqual(lease.keepAliveProcessIdentifier, pid, "starting a held lease keeps its child")

        lease.stop()
        lease.stop()
        XCTAssertFalse(lease.isHeld)
        XCTAssertFalse(isAlive(pid))
    }

    func testReleasingTheLeaseTerminatesTheChild() throws {
        var lease: CoreDeviceTunnelLease? = CoreDeviceTunnelLease(
            device: device, keepAlive: Self.sleeper, tunnelStates: ScriptedTunnelStates(["connected"]),
            terminationGrace: shortGrace)
        try lease?.start(timeout: 5)
        let pid = try XCTUnwrap(lease?.keepAliveProcessIdentifier)
        lease = nil
        XCTAssertFalse(isAlive(pid))
    }

    /// A child that ignores SIGTERM is killed once the grace period ends.
    func testAChildIgnoringTerminateIsKilled() throws {
        let stubborn = CoreDeviceTunnelLease.KeepAliveCommand(executableURL: URL(fileURLWithPath: "/bin/sh")) { _ in
            ["-c", "trap '' TERM; exec /bin/sleep 30"]
        }
        let lease = CoreDeviceTunnelLease(device: device, keepAlive: stubborn,
                                          tunnelStates: ScriptedTunnelStates(["connected"]), terminationGrace: shortGrace)
        try lease.start(timeout: 5)
        let pid = try XCTUnwrap(lease.keepAliveProcessIdentifier)
        Thread.sleep(forTimeInterval: 0.2)
        lease.stop()
        XCTAssertFalse(isAlive(pid))
    }

    /// devicectl records why it gave up in its JSON output; the lease reports it.
    func testChildExitCarriesTheCoreDeviceFailureItReported() throws {
        let json = """
            {"error":{"code":10005,"domain":"com.apple.dt.CoreDeviceError",\
            "userInfo":{"NSLocalizedDescription":{"string":"The operation failed because Developer Mode is disabled."}}},\
            "info":{"outcome":"failed"}}
            """
        let lease = CoreDeviceTunnelLease(device: device, keepAlive: Self.exiting(status: 1, json: json),
                                          tunnelStates: ScriptedTunnelStates(["connecting"]), terminationGrace: shortGrace)
        XCTAssertThrowsError(try lease.start(timeout: 10)) { error in
            let failure = CoreDeviceFailure(domain: "com.apple.dt.CoreDeviceError", code: 10005,
                                            localizedDescription: "The operation failed because Developer Mode is disabled.")
            XCTAssertEqual(error as? CoreDeviceTunnelError, .keepAliveExited(status: 1, failure: failure))
            XCTAssertEqual(failure.reason, .developerModeDisabled)
        }
        XCTAssertFalse(lease.isHeld)
    }

    func testChildExitWithoutJSONStillReportsItsStatus() throws {
        let lease = CoreDeviceTunnelLease(
            device: device,
            keepAlive: .init(executableURL: URL(fileURLWithPath: "/bin/sh")) { _ in ["-c", "exit 3"] },
            tunnelStates: ScriptedTunnelStates(["connecting"]), terminationGrace: shortGrace)
        XCTAssertThrowsError(try lease.start(timeout: 10)) { error in
            XCTAssertEqual(error as? CoreDeviceTunnelError, .keepAliveExited(status: 3, failure: nil))
        }
    }

    func testTunnelThatNeverConnectsTimesOutAndStopsTheChild() throws {
        let lease = CoreDeviceTunnelLease(device: device, keepAlive: Self.sleeper,
                                          tunnelStates: ScriptedTunnelStates(["unavailable"]), terminationGrace: shortGrace)
        XCTAssertThrowsError(try lease.start(timeout: 1)) { error in
            XCTAssertEqual(error as? CoreDeviceTunnelError, .tunnelNotConnected(device: device, tunnelState: "unavailable"))
        }
        XCTAssertFalse(lease.isHeld)
        XCTAssertNil(lease.keepAliveProcessIdentifier)
    }

    func testUnlaunchableChildIsATypedError() {
        let lease = CoreDeviceTunnelLease(
            device: device, keepAlive: .init(executableURL: URL(fileURLWithPath: "/nonexistent/devicectl")) { _ in [] },
            tunnelStates: ScriptedTunnelStates(["connected"]))
        XCTAssertThrowsError(try lease.start(timeout: 1)) { error in
            guard case .keepAliveLaunchFailed? = error as? CoreDeviceTunnelError else { return XCTFail("\(error)") }
        }
    }

    func testDevicectlObserveArguments() {
        let command = CoreDeviceTunnelLease.KeepAliveCommand.devicectlObserve(device: device, sessionTimeout: 120)
        XCTAssertEqual(command.executableURL.path, "/usr/bin/xcrun")
        XCTAssertEqual(command.arguments("/tmp/out.json"), [
            "devicectl", "device", "notification", "observe", "--device", device,
            "--name", CoreDeviceTunnelLease.leaseNotificationName,
            "--session-timeout", "120", "--timeout", "180", "--quiet", "--json-output", "/tmp/out.json",
        ])
    }

    // MARK: - devicectl JSON

    /// Captured from `xcrun devicectl list devices --json-output` (devicectl
    /// 518.33) with the device's identifiers replaced; its tunnel is unavailable.
    private func unavailable() throws -> Data { try Fixture.data("devicectl_unavailable", "json") }
    /// The same document with `tunnelState: connected`, plus a second device listed first.
    private func connected() throws -> Data { try Fixture.data("devicectl_connected", "json") }

    func testTunnelStateMatchedByIdentifierUDIDOrName() throws {
        for key in [device, "00008140-0000000000000001", "testphone"] {
            XCTAssertEqual(try DevicectlDeviceList.tunnelState(ofDevice: key, in: try connected()), "connected", key)
            XCTAssertEqual(try DevicectlDeviceList.tunnelState(ofDevice: key, in: try unavailable()), "unavailable", key)
        }
        XCTAssertEqual(try DevicectlDeviceList.tunnelState(ofDevice: "OtherPhone", in: try connected()), "unavailable")
    }

    func testUnknownDeviceAndGarbageAreTypedErrors() throws {
        XCTAssertThrowsError(try DevicectlDeviceList.tunnelState(ofDevice: "nope", in: try connected())) { error in
            XCTAssertEqual(error as? CoreDeviceTunnelError, .deviceNotFound("nope"))
        }
        XCTAssertThrowsError(try DevicectlDeviceList.tunnelState(ofDevice: "x", in: Data("{}".utf8))) { error in
            guard case .unrecognisedOutput? = error as? CoreDeviceTunnelError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try DevicectlDeviceList.tunnelState(ofDevice: "x", in: Data("not json".utf8)))
        XCTAssertNil(DevicectlDeviceList.failure(in: try connected()), "a successful document carries no error")
    }

    /// Runs the real `xcrun devicectl` on this machine: an unknown device must
    /// end in a typed error, never a crash or a bogus state.
    func testLiveDeviceListEndsInATypedError() {
        XCTAssertThrowsError(try DevicectlDeviceList().tunnelState(ofDevice: "mirroir-no-such-device")) { error in
            XCTAssertNotNil(error as? CoreDeviceTunnelError, "\(error)")
        }
    }
}
