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
// ABOUTME: Tests the trackpad fields stamped on scroll events, against values measured from real flicks.
// ABOUTME: Covers line and fixed-point deltas, velocity signs and axes, the sender, and the swipe plan's velocities.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

final class TrackpadScrollFieldsTests: XCTestCase {

    private func field(_ raw: UInt32) -> CGEventField {
        CGEventField(rawValue: raw)!
    }

    private func scrollEvent() throws -> CGEvent {
        try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: 0, wheel2: 0, wheel3: 0))
    }

    func testLineDeltaMatchesARealTrace() {
        XCTAssertEqual(TrackpadScrollFields.lineDelta(points: -55), -5)
        XCTAssertEqual(TrackpadScrollFields.lineDelta(points: -28), -2)
        XCTAssertEqual(TrackpadScrollFields.lineDelta(points: -9), -1)
        XCTAssertEqual(TrackpadScrollFields.lineDelta(points: 9), 1)
    }

    func testSmallFramesReportNoWholeLine() {
        XCTAssertEqual(TrackpadScrollFields.lineDelta(points: -2), 0)
        XCTAssertEqual(TrackpadScrollFields.lineDelta(points: 0), 0)
    }

    func testFixedDeltaIsSixteenDotSixteenLines() {
        XCTAssertEqual(TrackpadScrollFields.fixedDelta(points: 0), 0)
        let value = TrackpadScrollFields.fixedDelta(points: -55)
        XCTAssertEqual(Double(value) / TrackpadScrollFields.fixedPointScale, -5.39, accuracy: 0.01)
    }

    func testApplyWritesVerticalVelocityOppositeToTheDelta() throws {
        let event = try scrollEvent()
        TrackpadScrollFields.apply(
            to: event, step: SwipeWheelStep(wheel1: -51, wheel2: 0),
            velocity: TrackpadVelocity(axis1: -89.25, axis2: 0),
            momentumPhase: 0, senderID: nil)
        XCTAssertEqual(event.getDoubleValueField(field(178)), 89.25)
        XCTAssertEqual(event.getDoubleValueField(field(176)), 5, accuracy: 0.001)
        XCTAssertEqual(event.getDoubleValueField(field(177)), 0)
        XCTAssertEqual(event.getDoubleValueField(field(175)), 0)
    }

    func testApplyWritesHorizontalOnTheSecondAxisFields() throws {
        let event = try scrollEvent()
        TrackpadScrollFields.apply(
            to: event, step: SwipeWheelStep(wheel1: 0, wheel2: 51),
            velocity: TrackpadVelocity(axis1: 0, axis2: 89.25),
            momentumPhase: 0, senderID: nil)
        XCTAssertEqual(event.getDoubleValueField(field(177)), -89.25)
        XCTAssertEqual(event.getDoubleValueField(field(175)), -5, accuracy: 0.001)
        XCTAssertEqual(event.getIntegerValueField(field(12)), 5)
        XCTAssertEqual(event.getDoubleValueField(field(178)), 0)
    }

    func testApplyNamesTheSenderAndMarksTheEventAsTrackpad() throws {
        let event = try scrollEvent()
        let sender: UInt64 = 0x1_0000_F30C
        TrackpadScrollFields.apply(
            to: event, step: SwipeWheelStep(wheel1: -10, wheel2: 0), velocity: .zero,
            momentumPhase: 2, senderID: sender)
        XCTAssertEqual(event.getIntegerValueField(field(87)), Int64(sender))
        XCTAssertEqual(event.getIntegerValueField(field(45)), 1)
        XCTAssertEqual(event.getIntegerValueField(field(137)), 1)
        XCTAssertEqual(event.getIntegerValueField(field(173)), 2)
        XCTAssertEqual(event.flags, [])
    }

    func testApplyWithoutASenderLeavesTheSenderFieldEmpty() throws {
        let event = try scrollEvent()
        TrackpadScrollFields.apply(
            to: event, step: SwipeWheelStep(wheel1: -10, wheel2: 0), velocity: .zero,
            momentumPhase: 0, senderID: nil)
        XCTAssertEqual(event.getIntegerValueField(field(87)), 0)
    }

    func testDragVelocitiesLeadTheDeltas() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -700, durationMs: 150)
        XCTAssertEqual(plan.dragVelocities.count, plan.drag.count)
        for (step, velocity) in zip(plan.drag, plan.dragVelocities) {
            XCTAssertEqual(velocity.axis1,
                           Double(step.wheel1) * SwipeGestureProfile.dragVelocityPerPoint)
        }
    }

    func testMomentumVelocitiesCarryOnFromTheLiftAndDecay() throws {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -700, durationMs: 150)
        let velocities = plan.momentumVelocities
        XCTAssertEqual(velocities.count, plan.momentum.count)
        let lift = try XCTUnwrap(plan.dragVelocities.last)
        let first = try XCTUnwrap(velocities.first)
        XCTAssertEqual(first.axis1, lift.axis1 * SwipeGestureProfile.momentumDecayPerFrame)
        for (earlier, later) in zip(velocities, velocities.dropFirst()) {
            XCTAssertLessThan(abs(later.axis1), abs(earlier.axis1))
        }
    }

    func testASlowSwipeHasNoMomentumVelocities() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -100, durationMs: 1000)
        XCTAssertTrue(plan.momentum.isEmpty)
        XCTAssertTrue(plan.momentumVelocities.isEmpty)
    }

    func testAFastSwipeIsAFlickWithMomentum() {
        // 700px in 150ms = 4667 px/s, the speed of a real flick
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -700, durationMs: 150)
        XCTAssertFalse(plan.momentum.isEmpty)
        XCTAssertEqual(plan.durationMs, 150)
    }

    /// carnet#61: the 300 ms list scroll the explorers send is a drag at
    /// `maxDragSpeed`, so it never leaves a list held past its end.
    func testAListScrollIsStretchedToADragAtMaxSpeed() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -282, durationMs: 300)
        XCTAssertTrue(plan.momentum.isEmpty)
        XCTAssertEqual(plan.durationMs, Int((282 / SwipeGestureProfile.maxDragSpeed * 1000).rounded(.up)))
        XCTAssertEqual(plan.drag.reduce(0) { $0 + $1.wheel1 },
                       Int32(-282 * SwipeGestureProfile.dragAmplification))
    }

    /// carnet#44: a drag slower than `maxDragSpeed` keeps its own pace.
    func testASlowerDragKeepsItsDuration() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -100, durationMs: 2000)
        XCTAssertTrue(plan.momentum.isEmpty)
        XCTAssertEqual(plan.durationMs, 2000)
    }

    func testAVeryLongDragIsCapped() {
        let plan = SwipeGestureProfile.plan(deltaX: 0, deltaY: -100_000, durationMs: 60_000)
        XCTAssertEqual(plan.durationMs, SwipeGestureProfile.maxDragDurationMs)
    }

    func testTheFlickSpeedIsTheBoundary() {
        let velocity = SwipeGestureProfile.flickVelocity
        XCTAssertFalse(SwipeGestureProfile.plan(deltaX: 0, deltaY: velocity, durationMs: 1000).momentum.isEmpty)
        XCTAssertTrue(SwipeGestureProfile.plan(deltaX: 0, deltaY: velocity - 1, durationMs: 1000).momentum.isEmpty)
    }

    func testTheSenderLookupDoesNotReportAZeroID() {
        if let id = TrackpadScrollFields.senderDeviceID() {
            XCTAssertNotEqual(id, 0)
        }
    }

    /// carnet#42: a Mac with no trackpad still names a real device, its keyboard.
    func testTheSenderPrefersTheTrackpadThenTheKeyboard() {
        XCTAssertEqual(TrackpadScrollFields.senderServiceClasses.first, "AppleMultitouchDevice")
        XCTAssertTrue(TrackpadScrollFields.senderServiceClasses.contains("AppleHIDKeyboardEventDriverV2"))
    }
}
