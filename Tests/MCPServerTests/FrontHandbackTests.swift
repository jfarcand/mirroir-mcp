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
// ABOUTME: Tests that a swipe or drag returns the front app and pointer it borrowed, and only what it borrowed.
// ABOUTME: The Mac is a scripted double: no real window comes forward and the real pointer does not move.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

/// A scripted Mac: reports owners in order (the last repeats) and records what is asked of it.
private final class ScriptedMac: @unchecked Sendable {
    var owners: [pid_t?]
    var broughtForward: [pid_t] = []
    var pointerMoves: [CGPoint] = []
    let pointer = CGPoint(x: 900, y: 40)

    init(owners: [pid_t?]) { self.owners = owners }

    var front: MacFront {
        MacFront(
            ownerPID: { [self] in owners.count > 1 ? owners.removeFirst() : owners.first ?? nil },
            bringForward: { [self] in broughtForward.append($0) },
            pointer: { [self] in pointer },
            movePointer: { [self] in pointerMoves.append($0) })
    }
}

final class FrontHandbackTests: XCTestCase {

    private let iTerm: pid_t = 100
    private let mirror: pid_t = 777

    func testAGestureThatTookTheFrontReturnsItAndThePointer() {
        let mac = ScriptedMac(owners: [iTerm, mirror])
        FrontHandback.remember(mac.front, targetPID: mirror).finish(targetPID: mirror)
        XCTAssertEqual(mac.broughtForward, [iTerm])
        XCTAssertEqual(mac.pointerMoves, [mac.pointer])
    }

    func testATargetAlreadyInFrontKeepsIt() {
        let mac = ScriptedMac(owners: [mirror, mirror])
        FrontHandback.remember(mac.front, targetPID: mirror).finish(targetPID: mirror)
        XCTAssertTrue(mac.broughtForward.isEmpty, "the user was watching the mirror")
        XCTAssertTrue(mac.pointerMoves.isEmpty)
    }

    func testARefusedGestureMovesNoFront() {
        let mac = ScriptedMac(owners: [iTerm, iTerm])
        FrontHandback.remember(mac.front, targetPID: mirror).finish(targetPID: mirror)
        XCTAssertTrue(mac.broughtForward.isEmpty)
    }

    func testAUserWhoMovedOnIsNotPulledBack() {
        let safari: pid_t = 200
        let mac = ScriptedMac(owners: [iTerm, safari])
        FrontHandback.remember(mac.front, targetPID: mirror).finish(targetPID: mirror)
        XCTAssertTrue(mac.broughtForward.isEmpty, "the mirror does not own the front, so nothing is undone")
    }

    func testNoFrontOwnerMeansNothingToReturn() {
        let mac = ScriptedMac(owners: [nil, mirror])
        FrontHandback.remember(mac.front, targetPID: mirror).finish(targetPID: mirror)
        XCTAssertTrue(mac.broughtForward.isEmpty)
    }

    /// A desktop target is meant to be in front, so it borrows nothing.
    func testATargetWithNoWindowPosterKeepsTheFront() {
        let mac = ScriptedMac(owners: [iTerm, mirror])
        let input = InputSimulation(bridge: StubBridge(), keyboardLayouts: .usQWERTY, macFront: mac.front)
        input.beginFrontHandback().finish(targetPID: mirror)
        XCTAssertTrue(mac.broughtForward.isEmpty)
    }

    func testAMirrorTargetRemembersTheFront() {
        let mac = ScriptedMac(owners: [])
        let input = InputSimulation(bridge: StubBridge(), keyboardLayouts: .usQWERTY,
                                    windowPoster: RecordingWindowPoster(), macFront: mac.front)
        mac.owners = [iTerm, input.targetPID]
        let handback = input.beginFrontHandback()
        handback.finish(targetPID: input.targetPID)
        XCTAssertEqual(mac.broughtForward, [iTerm])
    }
}
