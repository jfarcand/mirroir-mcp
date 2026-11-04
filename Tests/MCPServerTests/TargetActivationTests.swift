// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the TargetActivation sequence over scripted system actions.
// ABOUTME: Pins that activation is confirmed, that raising is the second resort, and that an unconfirmed front refuses.

import Foundation
import XCTest
@testable import mirroir_mcp

/// Scripted system actions. Mock rationale: focus, Spaces and minimized windows
/// cannot be arranged from a unit test; each script answers `isFront` from a
/// queue so a test states exactly when the window server reports the front.
private final class ScriptedSystem: @unchecked Sendable {
    var running = true
    /// Answers to successive isFront calls; the last one repeats.
    var frontAnswers: [Bool]
    private(set) var log: [String] = []
    private(set) var waited: UInt32 = 0

    init(frontAnswers: [Bool]) { self.frontAnswers = frontAnswers }

    var steps: ActivationSteps {
        ActivationSteps(
            isRunning: { self.running },
            isFront: {
                self.log.append("check")
                return self.frontAnswers.count > 1
                    ? self.frontAnswers.removeFirst() : self.frontAnswers[0]
            },
            requestFront: { self.log.append("request") },
            raiseWindow: { self.log.append("raise") },
            wait: { self.waited += $0 },
            frontOwnerName: { "Terminal" })
    }

    func run() -> ActivationOutcome {
        TargetActivation.run(targetName: "iphone", steps: steps, settleUs: 300,
                             confirmTimeoutUs: 1_000, pollUs: 100)
    }
}

final class TargetActivationTests: XCTestCase {

    func testAlreadyFrontTouchesNothing() {
        let system = ScriptedSystem(frontAnswers: [true])
        XCTAssertEqual(system.run(), .alreadyFront)
        XCTAssertEqual(system.log, ["check"])
        XCTAssertEqual(system.waited, 0)
    }

    func testConfirmedRequestActivatesWithoutRaising() {
        let system = ScriptedSystem(frontAnswers: [false, true])
        XCTAssertEqual(system.run(), .activated)
        XCTAssertEqual(system.log, ["check", "request", "check"])
        XCTAssertEqual(system.waited, 300)
    }

    func testUnconfirmedRequestRaisesThenActivates() {
        let system = ScriptedSystem(frontAnswers: [false, false, false, true])
        XCTAssertEqual(system.run(), .activated)
        XCTAssertEqual(system.log, ["check", "request", "check", "raise", "check", "check"])
        // settle after the request, two polls, settle after the confirmation
        XCTAssertEqual(system.waited, 300 + 100 + 100 + 300)
    }

    func testNeverConfirmedRefusesAndNamesTheFrontApp() {
        let system = ScriptedSystem(frontAnswers: [false])
        guard case .failed(let reason) = system.run() else {
            return XCTFail("an unconfirmed front must refuse")
        }
        XCTAssertTrue(reason.contains("Terminal"), reason)
        XCTAssertTrue(reason.contains("No input was sent"), reason)
        XCTAssertEqual(system.log.filter { $0 == "raise" }.count, 1)
        // settle plus the whole confirmation window
        XCTAssertEqual(system.waited, 300 + 1_000)
    }

    func testNotRunningRefusesBeforeAnyRequest() {
        let system = ScriptedSystem(frontAnswers: [false])
        system.running = false
        guard case .failed(let reason) = system.run() else {
            return XCTFail("a missing process must refuse")
        }
        XCTAssertTrue(reason.contains("not running"), reason)
        XCTAssertTrue(system.log.isEmpty)
    }
}
