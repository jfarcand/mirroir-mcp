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
// ABOUTME: Unit tests for SwipeGestureProfile — drag/momentum delta schedules
// ABOUTME: for swipe gestures, including flick gating and displacement sums.

import XCTest

@testable import mirroir_mcp

final class SwipeGestureProfileTests: XCTestCase {

    private func totalWheel1(_ plan: SwipeGestureProfile.Plan) -> Int32 {
        plan.drag.reduce(0) { $0 + $1.wheel1 } + plan.momentum.reduce(0) { $0 + $1.wheel1 }
    }

    private func totalWheel2(_ plan: SwipeGestureProfile.Plan) -> Int32 {
        plan.drag.reduce(0) { $0 + $1.wheel2 } + plan.momentum.reduce(0) { $0 + $1.wheel2 }
    }

    // MARK: - Displacement conservation

    func testFlickConservesTotalDisplacement() {
        // TikTok-style vertical flick: 300px up in 100ms (issue #33)
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -300, durationMs: 100)
        let expected = Int32(-300 * SwipeGestureProfile.scrollAmplification)
        XCTAssertEqual(totalWheel1(plan), expected)
        XCTAssertEqual(totalWheel2(plan), 0)
    }

    func testSlowScrollConservesTotalDisplacement() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: 550, durationMs: 6000)
        let expected = Int32(550 * SwipeGestureProfile.dragAmplification)
        XCTAssertEqual(totalWheel1(plan), expected)
        XCTAssertEqual(totalWheel2(plan), 0)
    }

    func testHorizontalFlickConservesTotalDisplacement() {
        // Share-sheet row flick: 150px left in 50ms (issue #25 geometry)
        let plan = SwipeGestureProfile.plan(deltaX: -150, deltaY: 0, durationMs: 50)
        let expected = Int32(-150 * SwipeGestureProfile.scrollAmplification)
        XCTAssertEqual(totalWheel2(plan), expected)
        XCTAssertEqual(totalWheel1(plan), 0)
    }

    // MARK: - Flick gating

    func testFastSwipeGetsMomentumTail() {
        // 300px in 100ms = 3000 px/s, above the flick speed
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -300, durationMs: 100)
        XCTAssertFalse(plan.momentum.isEmpty)
    }

    func testSlowSwipeGetsNoMomentumTail() {
        // 550px in 6000ms = 92 px/s, a deliberate drag-scroll
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -550, durationMs: 6000)
        XCTAssertTrue(plan.momentum.isEmpty)
    }

    func testThresholdVelocityIsAFlick() {
        // Exactly at the flick speed: 2000px in 1000ms
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: SwipeGestureProfile.flickVelocity, durationMs: 1000)
        XCTAssertFalse(plan.momentum.isEmpty)
    }

    func testDiagonalVelocityUsesEuclideanDistance() {
        // 300px on each axis in 150ms: hypot = 424px -> 2828 px/s, a flick
        let plan = SwipeGestureProfile.plan(deltaX: 300, deltaY: 300, durationMs: 150)
        XCTAssertFalse(plan.momentum.isEmpty)
    }

    // MARK: - Direction symmetry (issue #25 regression guard)

    func testHorizontalPlansAreSymmetric() {
        let leftward = SwipeGestureProfile.plan(deltaX: -150, deltaY: 0, durationMs: 50)
        let rightward = SwipeGestureProfile.plan(deltaX: 150, deltaY: 0, durationMs: 50)
        XCTAssertEqual(leftward.drag.count, rightward.drag.count)
        XCTAssertEqual(leftward.momentum.count, rightward.momentum.count)
        for (l, r) in zip(leftward.drag, rightward.drag) {
            XCTAssertEqual(l.wheel2, -r.wheel2)
            XCTAssertEqual(l.wheel1, 0)
            XCTAssertEqual(r.wheel1, 0)
        }
        for (l, r) in zip(leftward.momentum, rightward.momentum) {
            XCTAssertEqual(l.wheel2, -r.wheel2)
        }
    }

    func testVerticalPlansAreSymmetric() {
        let upward = SwipeGestureProfile.plan(deltaX: 0, deltaY: -400, durationMs: 100)
        let downward = SwipeGestureProfile.plan(deltaX: 0, deltaY: 400, durationMs: 100)
        XCTAssertEqual(upward.drag.count, downward.drag.count)
        for (u, d) in zip(upward.drag, downward.drag) {
            XCTAssertEqual(u.wheel1, -d.wheel1)
        }
        for (u, d) in zip(upward.momentum, downward.momentum) {
            XCTAssertEqual(u.wheel1, -d.wheel1)
        }
    }

    // MARK: - Momentum shape

    func testMomentumDeltasDecay() {
        // Cumulative rounding introduces ±1 jitter between adjacent frames,
        // so assert the decay trend: the first half of the tail carries more
        // displacement than the second half, and the tail ends smaller than
        // it starts.
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -400, durationMs: 100)
        let magnitudes = plan.momentum.map { abs(Int($0.wheel1)) }
        XCTAssertFalse(magnitudes.isEmpty)
        let firstHalf = magnitudes.prefix(magnitudes.count / 2).reduce(0, +)
        let secondHalf = magnitudes.suffix(magnitudes.count / 2).reduce(0, +)
        XCTAssertGreaterThan(firstHalf, secondHalf)
        XCTAssertGreaterThanOrEqual(magnitudes.first ?? 0, magnitudes.last ?? 0)
    }

    func testFlickIsMomentumDominant() {
        // A real trackpad flick delivers most of its displacement in the
        // momentum tail (~70% in captured traces).
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -400, durationMs: 100)
        let dragSum = abs(plan.drag.reduce(0) { $0 + Int($1.wheel1) })
        let momentumSum = abs(plan.momentum.reduce(0) { $0 + Int($1.wheel1) })
        XCTAssertGreaterThan(momentumSum, dragSum)
    }

    func testMomentumVelocityIsContinuousAtLift() {
        // The first momentum frame continues from the drag's peak velocity —
        // no jump up at the finger lift.
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -400, durationMs: 100)
        let lastDrag = abs(Int(plan.drag.last?.wheel1 ?? 0))
        let firstMomentum = abs(Int(plan.momentum.first?.wheel1 ?? 0))
        XCTAssertLessThanOrEqual(firstMomentum, lastDrag + 1)
        XCTAssertGreaterThan(firstMomentum, 0)
    }

    func testDragRampsUpToPeakVelocity() {
        // Drag frames of a flick ramp from near rest to peak velocity,
        // matching the captured real-flick trace shape.
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -400, durationMs: 100)
        let magnitudes = plan.drag.map { abs(Int($0.wheel1)) }
        let first = magnitudes.first ?? 0
        let last = magnitudes.last ?? 0
        XCTAssertGreaterThan(last, first)
    }

    func testMomentumSignMatchesGestureDirection() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -400, durationMs: 100)
        for step in plan.momentum {
            XCTAssertLessThanOrEqual(step.wheel1, 0)
        }
    }

    func testMomentumTrimsTrailingZeroFrames() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -400, durationMs: 100)
        if let last = plan.momentum.last {
            XCTAssertFalse(last.wheel1 == 0 && last.wheel2 == 0)
        }
        XCTAssertLessThanOrEqual(plan.momentum.count, SwipeGestureProfile.momentumMaxSteps)
    }

    // MARK: - Drag shape

    func testDragStepCountFollowsDuration() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -1000, durationMs: 320)
        XCTAssertEqual(plan.drag.count, 320 / SwipeGestureProfile.frameMs)
    }

    func testShortDurationUsesMinimumDragSteps() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -400, durationMs: 10)
        XCTAssertEqual(plan.drag.count, SwipeGestureProfile.minimumDragSteps)
    }

    func testZeroDistanceProducesZeroDeltas() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: 0, durationMs: 300)
        XCTAssertEqual(totalWheel1(plan), 0)
        XCTAssertEqual(totalWheel2(plan), 0)
        XCTAssertTrue(plan.momentum.isEmpty)
    }

    func testZeroDurationDoesNotCrash() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -100, durationMs: 0)
        XCTAssertEqual(plan.drag.count, SwipeGestureProfile.minimumDragSteps)
        XCTAssertEqual(totalWheel1(plan), Int32(-100 * SwipeGestureProfile.scrollAmplification))
    }

    // MARK: - Totality (never traps on extreme input)

    func testNegativeDurationDoesNotCrash() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -100, durationMs: -5000)
        XCTAssertEqual(plan.drag.count, SwipeGestureProfile.minimumDragSteps)
        XCTAssertEqual(totalWheel1(plan), Int32(-100 * SwipeGestureProfile.scrollAmplification))
    }

    func testExtremeCoordinatesSaturateWithoutTrapping() {
        // A delta whose amplified value exceeds Int32 must saturate, not trap.
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: 1e12, durationMs: 300)
        XCTAssertEqual(totalWheel1(plan), Int32.max)
    }

    func testExtremeNegativeCoordinatesSaturateWithoutTrapping() {
        let plan = SwipeGestureProfile.plan(deltaX: -1e12, deltaY: 0, durationMs: 300)
        XCTAssertEqual(totalWheel2(plan), Int32.min)
    }

    func testNonFiniteCoordinatesProduceZeroDelta() {
        let plan = SwipeGestureProfile.plan(deltaX: .nan, deltaY: .infinity, durationMs: 300)
        XCTAssertEqual(totalWheel1(plan), 0)
        XCTAssertEqual(totalWheel2(plan), 0)
    }
}
