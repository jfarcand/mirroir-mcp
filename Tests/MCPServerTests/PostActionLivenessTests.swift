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
