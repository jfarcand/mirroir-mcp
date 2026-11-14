// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the pointing bounds check that re-reads the window once before refusing a point.
// ABOUTME: A window caught at a passing size (Mission Control thumbnail) must not be taken for the window's size.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

/// Hands out a scripted sequence of window reads, one per call; the last repeats.
/// Stands in for a window seen mid-animation, which cannot be produced on demand.
private final class ScriptedWindowBridge: WindowBridging, @unchecked Sendable {
    let targetName = "iphone"
    private let lock = NSLock()
    private var reads: [WindowInfo?]
    private(set) var readCount = 0

    init(_ reads: [WindowInfo?]) { self.reads = reads }

    func findProcess() -> NSRunningApplication? { nil }
    func getWindowInfo() -> WindowInfo? {
        lock.withLock {
            readCount += 1
            return reads.count > 1 ? reads.removeFirst() : reads[0]
        }
    }
    func getState() -> WindowState { .connected }
    func getOrientation() -> DeviceOrientation? { .portrait }
    func activate() {}
}

final class InputSimulationWindowBoundsTests: XCTestCase {

    private let mirror = WindowInfo(windowID: 1, position: .zero,
                                    size: CGSize(width: 430, height: 942), pid: 1)
    private let thumbnail = WindowInfo(windowID: 1, position: .zero,
                                       size: CGSize(width: 155, height: 339), pid: 1)

    func testPointInsideFirstReadNeedsNoRereading() {
        let bridge = ScriptedWindowBridge([mirror])
        let simulation = InputSimulation(bridge: bridge)
        let result = simulation.windowContaining(x: 215, y: 612, info: mirror, tag: "test")
        XCTAssertEqual(result.info?.size, mirror.size)
        XCTAssertNil(result.error)
        XCTAssertEqual(bridge.readCount, 0, "a point that fits the first read must not re-read")
    }

    func testPassingThumbnailSizeIsReplacedByTheFreshRead() {
        let bridge = ScriptedWindowBridge([mirror])
        let simulation = InputSimulation(bridge: bridge)
        let result = simulation.windowContaining(x: 215, y: 612, info: thumbnail, tag: "swipe")
        XCTAssertEqual(result.info?.size, mirror.size, "the fresh read is the window the swipe goes to")
        XCTAssertNil(result.error)
        XCTAssertEqual(bridge.readCount, 2, "two re-reads that agree")
    }

    func testSizeStillChangingIsReportedAsAMovingWindow() throws {
        let midway = WindowInfo(windowID: 1, position: .zero,
                                size: CGSize(width: 200, height: 450), pid: 1)
        let bridge = ScriptedWindowBridge([midway, mirror])
        let simulation = InputSimulation(bridge: bridge)
        let result = simulation.windowContaining(x: 215, y: 612, info: thumbnail, tag: "swipe")
        XCTAssertNil(result.info)
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.contains("155x339, then 200x450, then 430x942"), error)
        XCTAssertTrue(error.contains("being moved or resized"), error)
        XCTAssertTrue(error.contains("Nothing was sent"), error)
    }

    func testTwoDisagreeingReadsThatBothFitAreStillRefused() throws {
        let moving = WindowInfo(windowID: 1, position: CGPoint(x: 40, y: 30),
                                size: CGSize(width: 430, height: 942), pid: 1)
        let bridge = ScriptedWindowBridge([moving, mirror])
        let simulation = InputSimulation(bridge: bridge)
        let result = simulation.windowContaining(x: 215, y: 612, info: thumbnail, tag: "swipe")
        XCTAssertNil(result.info, "a window still moving is no place to send a swipe")
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.contains("being moved or resized"), error)
    }

    func testWindowSettledAtANewSizeRefusesForTheCoordinates() throws {
        let midway = WindowInfo(windowID: 1, position: .zero,
                                size: CGSize(width: 200, height: 450), pid: 1)
        let bridge = ScriptedWindowBridge([midway])
        let simulation = InputSimulation(bridge: bridge)
        let result = simulation.windowContaining(x: 215, y: 612, info: thumbnail, tag: "swipe")
        XCTAssertNil(result.info)
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.contains("outside the 'iphone' window (200x450)"), error)
    }

    func testPointOutsideASteadyWindowKeepsTheCoordinateRefusal() throws {
        let bridge = ScriptedWindowBridge([mirror])
        let simulation = InputSimulation(bridge: bridge)
        let result = simulation.windowContaining(x: 500, y: 612, info: mirror, tag: "tap")
        XCTAssertNil(result.info)
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.contains("Coordinates (500, 612) are outside"), error)
        XCTAssertFalse(error.contains("being moved"), error)
        XCTAssertEqual(bridge.readCount, 2)
    }

    func testMissingWindowOnRereadKeepsTheFirstRefusal() throws {
        let bridge = ScriptedWindowBridge([nil])
        let simulation = InputSimulation(bridge: bridge)
        let result = simulation.windowContaining(x: 215, y: 612, info: thumbnail, tag: "swipe")
        XCTAssertNil(result.info)
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.contains("(155x339)"), error)
    }

    func testEveryPointMustFitTheFreshRead() throws {
        let bridge = ScriptedWindowBridge([mirror])
        let simulation = InputSimulation(bridge: bridge)
        let points = [CGPoint(x: 100, y: 100), CGPoint(x: 215, y: 2000)]
        let result = simulation.windowContaining(points: points, info: thumbnail, tag: "swipe")
        XCTAssertNil(result.info)
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.contains("(215, 2000)"), error)
    }
}
