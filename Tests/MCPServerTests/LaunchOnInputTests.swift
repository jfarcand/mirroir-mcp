// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that an input call launches a stopped iPhone Mirroring in the background and waits out "Connecting".
// ABOUTME: Pins that a running target is never relaunched, a refused launch keeps the not-running refusal, and Connect is a resume control.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

/// Accepts every window event and posts nothing, so taps here never reach
/// the Mac's event stream.
private struct SilentWindowPoster: WindowEventPosting {
    func postButton(down: Bool, at point: CGPoint, clickCount: Int, in window: WindowInfo) -> Bool { true }
    func focusKeys(in window: WindowInfo) -> Bool { true }
    func pause(microseconds: UInt32) {}
    var canStampEvents: Bool { true }
    func stamp(_ event: CGEvent, at point: CGPoint, in window: WindowInfo) {}
}

final class LaunchOnInputTests: XCTestCase {

    /// A target that is not a running process on the test Mac, with a window
    /// poster so a tap that goes through needs no activation.
    private func makeInput(_ bridge: StubBridge) -> InputSimulation {
        bridge.processRunning = false
        bridge.frontmost = false
        return InputSimulation(bridge: bridge, keyboardLayout: .usQWERTY,
                               windowPoster: SilentWindowPoster())
    }

    func testATapOnAStoppedTargetLaunchesItInTheBackgroundFirst() {
        let bridge = StubBridge()
        bridge.state = .notRunning
        bridge.launchedState = .connected

        XCTAssertNil(makeInput(bridge).tap(x: 100, y: 200, cursorMode: nil))
        XCTAssertEqual(bridge.launchCount, 1)
    }

    func testARunningTargetIsNeverLaunched() {
        let bridge = StubBridge()
        bridge.launchedState = .connected

        XCTAssertNil(makeInput(bridge).tap(x: 100, y: 200, cursorMode: nil))
        XCTAssertEqual(bridge.launchCount, 0)
    }

    func testARefusedLaunchKeepsTheNotRunningRefusal() {
        let bridge = StubBridge()
        bridge.state = .notRunning

        let message = makeInput(bridge).tap(x: 100, y: 200, cursorMode: nil)

        XCTAssertEqual(message, "Target 'iphone' is not running. Launch iPhone Mirroring first.")
        XCTAssertEqual(bridge.launchCount, 1)
    }

    /// A cold launch reads "Connecting to" for a few seconds: the call waits
    /// for it rather than refusing while the session comes up.
    func testTheCallWaitsWhileTheLaunchedSessionConnects() {
        let bridge = StubBridge()
        bridge.state = .notRunning
        bridge.launchedState = .paused
        bridge.block = SessionBlock(quoted: ["Connecting to iPhone"], move: .waitWhileConnecting)
        bridge.connectsAt = Date().addingTimeInterval(0.6)

        XCTAssertNil(makeInput(bridge).tap(x: 100, y: 200, cursorMode: nil))
    }

    /// A block waiting cannot clear ends the wait at once and is quoted.
    func testABlockThatNeedsTheUserEndsTheWaitAndIsReported() {
        let bridge = StubBridge()
        bridge.state = .notRunning
        bridge.launchedState = .paused
        bridge.pressResumeResult = false
        bridge.block = SessionBlock(quoted: ["iPhone in Use"], move: .lockIPhone)

        let started = Date()
        let message = makeInput(bridge).tap(x: 100, y: 200, cursorMode: nil)

        XCTAssertTrue(message?.contains("“iPhone in Use”") ?? false, message ?? "nil")
        XCTAssertTrue(message?.contains("lock the iPhone") ?? false, message ?? "nil")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the launch timeout was not waited out")
    }

    func testConnectIsAResumeControlInEveryShippedLanguage() {
        for title in ["Connect", "Connecter", "Connexion", "Try Again", "Réessayer"] {
            XCTAssertTrue(MirroringWindowResolver.isResumeControl(label: title), title)
        }
    }
}
