// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for MultiTouchGesture validation and time resolution, and for MultiTouchCoordinateMapper.
// ABOUTME: Every validation error is exercised, plus portrait/landscape scaling and the orientation refusal.

import XCTest
import CoreGraphics
@testable import mirroir_mcp

final class MultiTouchGestureTests: XCTestCase {

    private let screen = CGSize(width: 390, height: 844)
    private let point = CGPoint(x: 10, y: 10)

    private func tap(_ id: Int, upMs: Int = 50) -> FingerTimeline {
        FingerTimeline(id: id, steps: [.down(point: point, atMs: nil), .up(atMs: upMs)])
    }

    private func validationError(_ timelines: [FingerTimeline],
                                 bounds: CGSize? = nil) -> MultiTouchValidationError? {
        do {
            _ = try MultiTouchGesture(timelines: timelines, bounds: bounds ?? screen)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Time resolution

    func testTimesDefaultToTheEndOfThePreviousStep() throws {
        let gesture = try MultiTouchGesture(timelines: [FingerTimeline(id: 3, steps: [
            .down(point: point, atMs: 100),
            .move(to: CGPoint(x: 20, y: 20), atMs: nil, durationMs: 200),
            .move(to: CGPoint(x: 30, y: 30), atMs: 500, durationMs: 100),
            .up(atMs: nil),
        ])], bounds: screen)
        XCTAssertEqual(gesture.paths, [FingerPath(
            id: 3, downPoint: point, downMs: 100,
            moves: [FingerMove(to: CGPoint(x: 20, y: 20), startMs: 100, durationMs: 200),
                    FingerMove(to: CGPoint(x: 30, y: 30), startMs: 500, durationMs: 100)],
            upMs: 600)])
        XCTAssertEqual(gesture.paths[0].upPoint, CGPoint(x: 30, y: 30))
        XCTAssertEqual(gesture.durationMs, 600)
    }

    func testDurationIsTheLastLift() throws {
        let gesture = try MultiTouchGesture(timelines: [tap(1, upMs: 300), tap(2, upMs: 900)],
                                            bounds: screen)
        XCTAssertEqual(gesture.durationMs, 900)
    }

    func testTenFingersAreAccepted() throws {
        let fingers = (1...MultiTouchGesture.maxFingers).map { tap($0) }
        XCTAssertEqual(try MultiTouchGesture(timelines: fingers, bounds: screen).paths.count, 10)
    }

    func testPointsOnTheScreenEdgeAreInside() {
        let corner = FingerTimeline(id: 1, steps: [
            .down(point: .zero, atMs: nil),
            .move(to: CGPoint(x: screen.width, y: screen.height), atMs: nil, durationMs: 10),
            .up(atMs: nil),
        ])
        XCTAssertNil(validationError([corner]))
    }

    // MARK: - Refusals

    func testFingerCountBounds() {
        XCTAssertEqual(validationError([]), .fingerCount(0))
        let eleven = (1...11).map { tap($0) }
        XCTAssertEqual(validationError(eleven), .fingerCount(11))
    }

    func testDuplicateIDs() {
        XCTAssertEqual(validationError([tap(1), tap(1)]), .duplicateFingerID(1))
    }

    func testTimelineShape() {
        XCTAssertEqual(validationError([FingerTimeline(id: 1, steps: [])]), .emptyTimeline(finger: 1))
        XCTAssertEqual(validationError([FingerTimeline(id: 1, steps: [.up(atMs: 5)])]),
                       .firstStepNotDown(finger: 1))
        XCTAssertEqual(validationError([FingerTimeline(id: 1, steps: [.down(point: point, atMs: 0)])]),
                       .lastStepNotUp(finger: 1))
        XCTAssertEqual(validationError([FingerTimeline(id: 1, steps: [
            .down(point: point, atMs: 0),
            .move(to: point, atMs: nil, durationMs: 10),
        ])]), .lastStepNotUp(finger: 1))
        XCTAssertEqual(validationError([FingerTimeline(id: 1, steps: [
            .down(point: point, atMs: 0), .down(point: point, atMs: 5), .up(atMs: 10),
        ])]), .misplacedStep(finger: 1, index: 1))
        XCTAssertEqual(validationError([FingerTimeline(id: 1, steps: [
            .down(point: point, atMs: 0), .up(atMs: 5), .up(atMs: 10),
        ])]), .misplacedStep(finger: 1, index: 1))
    }

    func testTimeRules() {
        XCTAssertEqual(validationError([FingerTimeline(id: 2, steps: [
            .down(point: point, atMs: -1), .up(atMs: 10),
        ])]), .negativeTime(finger: 2, index: 0, ms: -1))
        XCTAssertEqual(validationError([FingerTimeline(id: 2, steps: [
            .down(point: point, atMs: 100),
            .move(to: point, atMs: 50, durationMs: 10),
            .up(atMs: nil),
        ])]), .timeGoesBackwards(finger: 2, index: 1, atMs: 50, previousEndMs: 100))
        XCTAssertEqual(validationError([FingerTimeline(id: 2, steps: [
            .down(point: point, atMs: 0),
            .move(to: point, atMs: nil, durationMs: 300),
            .up(atMs: 200),
        ])]), .timeGoesBackwards(finger: 2, index: 2, atMs: 200, previousEndMs: 300))
        XCTAssertEqual(validationError([FingerTimeline(id: 2, steps: [
            .down(point: point, atMs: 40), .up(atMs: nil),
        ])]), .zeroLengthContact(finger: 2))
    }

    func testMoveDurationBounds() {
        for bad in [0, -5, MultiTouchGesture.maxDurationMs + 1] {
            XCTAssertEqual(validationError([FingerTimeline(id: 1, steps: [
                .down(point: point, atMs: 0), .move(to: point, atMs: nil, durationMs: bad), .up(atMs: nil),
            ])]), .moveDuration(finger: 1, index: 1, durationMs: bad))
        }
    }

    func testTotalDurationCap() {
        XCTAssertEqual(validationError([tap(1, upMs: MultiTouchGesture.maxDurationMs + 1)]),
                       .tooLong(durationMs: MultiTouchGesture.maxDurationMs + 1))
        XCTAssertNil(validationError([tap(1, upMs: MultiTouchGesture.maxDurationMs)]))
    }

    func testCoordinatesOutsideTheScreen() {
        let outside = CGPoint(x: 391, y: 10)
        XCTAssertEqual(validationError([FingerTimeline(id: 1, steps: [
            .down(point: point, atMs: 0), .move(to: outside, atMs: nil, durationMs: 10), .up(atMs: nil),
        ])]), .outOfBounds(finger: 1, index: 1, point: outside, bounds: screen))
        XCTAssertEqual(validationError([FingerTimeline(id: 1, steps: [
            .down(point: CGPoint(x: -1, y: 0), atMs: 0), .up(atMs: 5),
        ])]), .outOfBounds(finger: 1, index: 0, point: CGPoint(x: -1, y: 0), bounds: screen))
    }

    func testErrorsExplainThemselves() {
        XCTAssertTrue(MultiTouchValidationError.lastStepNotUp(finger: 1).description
            .contains("cannot stay down"))
        XCTAssertTrue(MultiTouchValidationError.outOfBounds(
            finger: 1, index: 2, point: CGPoint(x: 400.5, y: 3), bounds: screen).description
            .contains("(400.50, 3) is outside the 390x844 screen"))
    }

    // MARK: - Coordinate mapping

    func testPortraitWindowScalesToDevicePoints() throws {
        let window = CGSize(width: 410, height: 898)
        let mapped = try MultiTouchCoordinateMapper.map(
            [FingerTimeline(id: 1, steps: [
                .down(point: CGPoint(x: 205, y: 449), atMs: nil),
                .move(to: CGPoint(x: 410, y: 898), atMs: 10, durationMs: 100),
                .up(atMs: 500),
            ])], window: window, device: screen)
        XCTAssertEqual(mapped, [FingerTimeline(id: 1, steps: [
            .down(point: CGPoint(x: 195, y: 422), atMs: nil),
            .move(to: CGPoint(x: 390, y: 844), atMs: 10, durationMs: 100),
            .up(atMs: 500),
        ])])
    }

    func testLandscapeWindowScalesToLandscapeViewport() throws {
        let window = CGSize(width: 898, height: 410)
        let device = CGSize(width: 844, height: 390)
        XCTAssertEqual(MultiTouchCoordinateMapper.devicePoint(
            CGPoint(x: 449, y: 100), window: window, device: device),
            CGPoint(x: 422, y: 95.12))
        XCTAssertNoThrow(try MultiTouchCoordinateMapper.map([tap(1)], window: window, device: device))
    }

    func testOrientationMismatchIsRefused() {
        let window = CGSize(width: 898, height: 410)
        XCTAssertThrowsError(try MultiTouchCoordinateMapper.map([tap(1)], window: window, device: screen)) {
            XCTAssertEqual($0 as? MultiTouchMappingError,
                           .orientationMismatch(window: window, device: self.screen))
            XCTAssertTrue(String(describing: $0).contains("landscape"))
        }
    }

    func testDegenerateSizesAreRefused() {
        XCTAssertThrowsError(try MultiTouchCoordinateMapper.map(
            [tap(1)], window: .zero, device: screen)) {
            XCTAssertEqual($0 as? MultiTouchMappingError,
                           .degenerateSize(role: "mirroring window", size: .zero))
        }
        let infinite = CGSize(width: CGFloat.infinity, height: 10)
        XCTAssertThrowsError(try MultiTouchCoordinateMapper.map(
            [tap(1)], window: screen, device: infinite)) {
            XCTAssertEqual($0 as? MultiTouchMappingError,
                           .degenerateSize(role: "device viewport", size: infinite))
        }
    }
}
