// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for freeing a Continuity-interrupted (paused) iPhone Mirroring session.
// ABOUTME: Covers InputSimulation.freePausedSession / ensureConnected orchestration via StubBridge.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

final class PausedSessionRecoveryTests: XCTestCase {

    private func makeInput(_ bridge: StubBridge) -> InputSimulation {
        InputSimulation(bridge: bridge, layoutSubstitution: [:])
    }

    // MARK: - freePausedSession

    func testFreePausedSessionNoOpWhenConnected() {
        let bridge = StubBridge()
        bridge.state = .connected
        XCTAssertTrue(makeInput(bridge).freePausedSession(tag: "test"))
    }

    func testFreePausedSessionFreesViaResumeOverlay() {
        // No titled dismiss button → plain "click to resume" overlay: AX-press it.
        let bridge = StubBridge()
        bridge.state = .paused
        bridge.pausedButtonPoint = nil
        bridge.connectOnResume = true
        XCTAssertTrue(makeInput(bridge).freePausedSession(tag: "test"))
        XCTAssertEqual(bridge.state, .connected)
    }

    func testFreePausedSessionWaitsForAnEarlierClickBeforeGivingUp() {
        // Device capture (iPhone XR): the first escape freed the session, the
        // overlay was gone by the second attempt so no plugin applied, and the
        // state only read connected a moment later.
        let bridge = StubBridge()
        bridge.state = .paused
        bridge.pausedButtonPoint = nil
        bridge.pressResumeResults = [true, false]
        // Connected after the first attempt's settle check but within the second
        // attempt's settle time.
        let settle = TimeInterval(EnvConfig.resumeFromPausedUs) / 1_000_000
        bridge.connectsAt = Date().addingTimeInterval(settle * 1.5)
        XCTAssertTrue(makeInput(bridge).freePausedSession(tag: "test"))
    }

    // MARK: - ensureConnected

    func testEnsureConnectedNilWhenConnected() {
        let bridge = StubBridge()
        bridge.state = .connected
        XCTAssertNil(makeInput(bridge).ensureConnected(tag: "test"))
    }

    func testEnsureConnectedFreesPausedSessionThenProceeds() {
        // Paused on entry → freed via the resume overlay → reports connected (nil).
        let bridge = StubBridge()
        bridge.state = .paused
        bridge.connectOnResume = true
        XCTAssertNil(makeInput(bridge).ensureConnected(tag: "test"))
    }
}
