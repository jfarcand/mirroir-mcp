// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for GesturePlanner step math and event order, and for GestureRequest argument validation.
// ABOUTME: Pure value tests: no CGEvent is created or posted.

import XCTest
@testable import mirroir_mcp

final class GesturePlannerTests: XCTestCase {

    private let tolerance = 1e-9

    // MARK: - Step math

    func testZoomDeltasMultiplyToExactlyTheScale() {
        for scale in [0.1, 0.5, 0.9, 1.01, 2.0, 3.7, 10.0] {
            for durationMs in [100, 333, 500, 5_000] {
                let frames = FramePacing.frameCount(durationMs: durationMs)
                let deltas = GesturePlanner.deltas(for: .pinch(scale: scale), frames: frames)
                XCTAssertEqual(deltas.count, frames)
                let spread = deltas.reduce(1.0) { $0 * (1 + $1) }
                XCTAssertEqual(spread, scale, accuracy: tolerance,
                               "scale \(scale) over \(durationMs)ms")
            }
        }
    }

    func testZoomDeltaSignFollowsDirection() {
        XCTAssertTrue(GesturePlanner.deltas(for: .pinch(scale: 2), frames: 10).allSatisfy { $0 > 0 })
        XCTAssertTrue(GesturePlanner.deltas(for: .pinch(scale: 0.5), frames: 10).allSatisfy { $0 < 0 })
    }

    func testRotateDeltasSumToTheDegrees() {
        for degrees in [-360.0, -45.0, 0.5, 90.0, 270.0] {
            for durationMs in [100, 500, 4_321] {
                let frames = FramePacing.frameCount(durationMs: durationMs)
                let deltas = GesturePlanner.deltas(for: .rotate(degrees: degrees), frames: frames)
                XCTAssertEqual(deltas.count, frames)
                XCTAssertEqual(deltas.reduce(0, +), degrees, accuracy: tolerance)
            }
        }
    }

    func testFrameCountIsSixtyFpsWithAFloor() {
        XCTAssertEqual(FramePacing.frameCount(durationMs: 100), FramePacing.minFrames)
        XCTAssertEqual(FramePacing.frameCount(durationMs: 800), 800 / FramePacing.frameMs)
        XCTAssertEqual(FramePacing.frameCount(durationMs: 5_000), 5_000 / FramePacing.frameMs)
    }

    // MARK: - Event order

    func testPinchSequenceIsPointerMoveBeganChangedEnded() {
        let durationMs = 500
        let frames = FramePacing.frameCount(durationMs: durationMs)
        let steps = GesturePlanner.steps(for: .pinch(scale: 2), durationMs: durationMs)
        XCTAssertEqual(steps.count, frames + 3)

        XCTAssertEqual(steps.first, GestureStep(events: [.pointerMove],
                                                pauseAfterUs: GesturePlanner.pointerSettleUs))
        XCTAssertEqual(steps[1].events, [.container, .gesture(.zoom, .began, delta: 0)])
        let changed = steps[2 ..< steps.count - 1]
        XCTAssertEqual(changed.count, frames)
        for step in changed {
            XCTAssertEqual(step.events.count, 2)
            XCTAssertEqual(step.events.first, .container, "a container precedes every sub-gesture event")
            guard case .gesture(.zoom, .changed, let delta) = step.events.last else {
                return XCTFail("expected a zoom changed event, got \(step.events)")
            }
            XCTAssertGreaterThan(delta, 0)
        }
        XCTAssertEqual(steps.last, GestureStep(events: [.container, .gesture(.zoom, .ended, delta: 0)],
                                               pauseAfterUs: 0))
    }

    func testRotateSequenceUsesRotateSubtype() {
        let steps = GesturePlanner.steps(for: .rotate(degrees: -90), durationMs: 200)
        let kinds = steps.flatMap(\.events).compactMap { event -> GestureKind? in
            if case .gesture(let kind, _, _) = event { return kind }
            return nil
        }
        XCTAssertFalse(kinds.isEmpty)
        XCTAssertTrue(kinds.allSatisfy { $0 == .rotate })
    }

    func testFramesArePacedOverTheDuration() {
        let durationMs = 800
        let frames = FramePacing.frameCount(durationMs: durationMs)
        let steps = GesturePlanner.steps(for: .pinch(scale: 0.5), durationMs: durationMs)
        let framePause = UInt32(durationMs) * 1000 / UInt32(frames)
        XCTAssertTrue(steps.dropFirst().dropLast().allSatisfy { $0.pauseAfterUs == framePause })
    }

    // MARK: - Argument validation

    private func message<T>(_ result: Result<T, GestureArgumentError>) -> String? {
        if case .failure(let error) = result { return error.message }
        return nil
    }

    func testPinchAcceptsInRangeScale() {
        XCTAssertEqual(GestureRequest.pinch(x: 10, y: 20, scale: 2, durationMs: 500),
                       .success(GestureRequest(x: 10, y: 20, gesture: .pinch(scale: 2), durationMs: 500)))
        XCTAssertNil(message(GestureRequest.pinch(x: 0, y: 0, scale: GestureRequest.minPinchScale,
                                                  durationMs: GestureRequest.minDurationMs)))
        XCTAssertNil(message(GestureRequest.pinch(x: 0, y: 0, scale: GestureRequest.maxPinchScale,
                                                  durationMs: GestureRequest.maxDurationMs)))
    }

    func testPinchRejectsNoOpOutOfRangeAndNonFiniteScale() {
        XCTAssertTrue(message(GestureRequest.pinch(x: 0, y: 0, scale: 1, durationMs: 500))?
            .contains("scale 1") ?? false)
        for scale in [0, -2, 0.05, 10.5, Double.nan, Double.infinity] {
            XCTAssertTrue(message(GestureRequest.pinch(x: 0, y: 0, scale: scale, durationMs: 500))?
                .contains("between") ?? false, "scale \(scale)")
        }
    }

    func testRotateRejectsZeroAndOutOfRangeDegrees() {
        XCTAssertTrue(message(GestureRequest.rotate(x: 0, y: 0, degrees: 0, durationMs: 500))?
            .contains("degrees 0") ?? false)
        for degrees in [361, -400, Double.nan] {
            XCTAssertNotNil(message(GestureRequest.rotate(x: 0, y: 0, degrees: degrees, durationMs: 500)),
                            "degrees \(degrees)")
        }
        XCTAssertNil(message(GestureRequest.rotate(x: 0, y: 0, degrees: -360, durationMs: 500)))
    }

    func testDurationBoundsApplyToBothGestures() {
        let tooShort = GestureRequest.minDurationMs - 1
        let tooLong = GestureRequest.maxDurationMs + 1
        XCTAssertTrue(message(GestureRequest.pinch(x: 0, y: 0, scale: 2, durationMs: tooShort))?
            .contains("pinch duration_ms") ?? false)
        XCTAssertTrue(message(GestureRequest.rotate(x: 0, y: 0, degrees: 30, durationMs: tooLong))?
            .contains("rotate duration_ms") ?? false)
    }

    func testNonFiniteCoordinatesAreRejected() {
        XCTAssertNotNil(message(GestureRequest.pinch(x: .nan, y: 0, scale: 2, durationMs: 500)))
        XCTAssertNotNil(message(GestureRequest.rotate(x: 0, y: .infinity, degrees: 30, durationMs: 500)))
    }
}
