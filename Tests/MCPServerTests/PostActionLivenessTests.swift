// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that a pointing action reports a session that stopped accepting input right after it.
// ABOUTME: Pins the liveness check's message so a tap that raises an interruption is never reported as plain success.

import XCTest
@testable import mirroir_mcp

final class PostActionLivenessTests: XCTestCase {

    private func makeInput(state: WindowState) -> InputSimulation {
        let bridge = StubBridge()
        // Not running as a process, so nothing on the test Mac is touched.
        bridge.processRunning = false
        bridge.state = state
        return InputSimulation(bridge: bridge, keyboardLayout: .usQWERTY)
    }

    func testAConnectedSessionAfterTheActionIsPlainSuccess() {
        XCTAssertNil(makeInput(state: .connected)
            .checkLivenessAfter(tag: "tap", action: "The tap"))
    }

    func testASessionThatPausedAfterTheActionIsReported() {
        let message = makeInput(state: .paused).checkLivenessAfter(tag: "tap", action: "The tap")
        XCTAssertEqual(message, "The tap was delivered, then 'iphone' stopped accepting input "
            + "(paused). Describe the screen before the next action.")
    }

    func testAWindowThatVanishedAfterTheActionIsReported() {
        let message = makeInput(state: .noWindow).checkLivenessAfter(tag: "swipe", action: "The swipe")
        XCTAssertTrue(message?.hasPrefix("The swipe was delivered") ?? false, message ?? "nil")
        XCTAssertTrue(message?.contains("noWindow") ?? false, message ?? "nil")
    }
}
