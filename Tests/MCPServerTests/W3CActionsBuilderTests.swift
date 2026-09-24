// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Pins the exact W3C actions JSON W3CActionsBuilder produces for multi-finger gestures.
// ABOUTME: Covers a tap, staggered starts, a long hold under another finger's moves, and independent lifts.

import XCTest
import CoreGraphics
@testable import mirroir_mcp

final class W3CActionsBuilderTests: XCTestCase {

    private let screen = CGSize(width: 390, height: 844)

    private func json(_ timelines: [FingerTimeline]) throws -> String {
        let gesture = try MultiTouchGesture(timelines: timelines, bounds: screen)
        return String(decoding: try W3CActionsBuilder.body(for: gesture), as: UTF8.self)
    }

    /// The JSON of one pointer source, as the builder sorts its keys.
    private func source(_ id: Int, _ actions: [String]) -> String {
        "{\"actions\":[" + actions.joined(separator: ",") + "],\"id\":\"finger\(id)\","
            + "\"parameters\":{\"pointerType\":\"touch\"},\"type\":\"pointer\"}"
    }

    private func body(_ sources: [String]) -> String {
        "{\"actions\":[" + sources.joined(separator: ",") + "]}"
    }

    private func place(_ x: Int, _ y: Int) -> String { move(x, y, 0) }

    private func move(_ x: Int, _ y: Int, _ duration: Int) -> String {
        "{\"duration\":\(duration),\"origin\":\"viewport\",\"type\":\"pointerMove\",\"x\":\(x),\"y\":\(y)}"
    }

    private func pause(_ duration: Int) -> String { "{\"duration\":\(duration),\"type\":\"pause\"}" }

    private let down = "{\"button\":0,\"type\":\"pointerDown\"}"
    private let up = "{\"button\":0,\"type\":\"pointerUp\"}"

    func testOneFingerTap() throws {
        let tap = FingerTimeline(id: 1, steps: [
            .down(point: CGPoint(x: 100, y: 200), atMs: nil), .up(atMs: 80),
        ])
        XCTAssertEqual(try json([tap]), body([source(1, [place(100, 200), down, pause(80), up])]))
    }

    func testTwoFingersWithStaggeredStart() throws {
        let first = FingerTimeline(id: 1, steps: [
            .down(point: CGPoint(x: 100, y: 100), atMs: 0), .up(atMs: 300),
        ])
        let second = FingerTimeline(id: 2, steps: [
            .down(point: CGPoint(x: 200, y: 400), atMs: 150), .up(atMs: 300),
        ])
        XCTAssertEqual(try json([first, second]), body([
            source(1, [place(100, 100), down, pause(300), up]),
            source(2, [pause(150), place(200, 400), down, pause(150), up]),
        ]))
    }

    func testOneFingerHeldTenSecondsWhileAnotherMoves() throws {
        let joystick = FingerTimeline(id: 0, steps: [
            .down(point: CGPoint(x: 80, y: 700), atMs: 0), .up(atMs: 10_000),
        ])
        let camera = FingerTimeline(id: 1, steps: [
            .down(point: CGPoint(x: 300, y: 400), atMs: 1_000),
            .move(to: CGPoint(x: 300, y: 200), atMs: nil, durationMs: 2_000),
            .move(to: CGPoint(x: 150, y: 200), atMs: 5_000, durationMs: 1_000),
            .up(atMs: 7_000),
        ])
        XCTAssertEqual(try json([joystick, camera]), body([
            source(0, [place(80, 700), down, pause(10_000), up]),
            source(1, [pause(1_000), place(300, 400), down, move(300, 200, 2_000),
                       pause(2_000), move(150, 200, 1_000), pause(1_000), up]),
        ]))
    }

    func testIndependentLifts() throws {
        let lifts = [(1, 200), (2, 800), (3, 500)]
        let timelines = lifts.map { id, liftMs in
            FingerTimeline(id: id, steps: [
                .down(point: CGPoint(x: 100 * id, y: 300), atMs: 0),
                .move(to: CGPoint(x: 100 * id, y: 350), atMs: nil, durationMs: 100),
                .up(atMs: liftMs),
            ])
        }
        XCTAssertEqual(try json(timelines), body([
            source(1, [place(100, 300), down, move(100, 350, 100), pause(100), up]),
            source(2, [place(200, 300), down, move(200, 350, 100), pause(700), up]),
            source(3, [place(300, 300), down, move(300, 350, 100), pause(400), up]),
        ]))
    }

    func testUpRightAfterAMoveNeedsNoPause() throws {
        let swipe = FingerTimeline(id: 4, steps: [
            .down(point: CGPoint(x: 10, y: 10), atMs: nil),
            .move(to: CGPoint(x: 10, y: 500), atMs: nil, durationMs: 250),
            .up(atMs: nil),
        ])
        XCTAssertEqual(W3CActionsBuilder.source(for: try MultiTouchGesture(
            timelines: [swipe], bounds: screen).paths[0]).actions, [
            .move(point: CGPoint(x: 10, y: 10), durationMs: 0), .down,
            .move(point: CGPoint(x: 10, y: 500), durationMs: 250), .up,
        ])
    }

    func testFractionalCoordinatesKeepTheirDecimals() throws {
        let tap = FingerTimeline(id: 1, steps: [
            .down(point: CGPoint(x: 100.25, y: 200.5), atMs: nil), .up(atMs: 10),
        ])
        XCTAssertTrue(try json([tap]).contains("\"x\":100.25,\"y\":200.5"))
    }

    /// Every finger's durations add up to its lift time: WebDriverAgent times
    /// an action at the sum of the durations before it in the same source.
    func testDurationsSumToEachFingersLiftTime() throws {
        let gesture = try MultiTouchGesture(timelines: [
            FingerTimeline(id: 1, steps: [.down(point: .zero, atMs: 40),
                                          .move(to: CGPoint(x: 5, y: 5), atMs: 90, durationMs: 60),
                                          .up(atMs: 400)]),
            FingerTimeline(id: 2, steps: [.down(point: .zero, atMs: 0), .up(atMs: 1_234)]),
        ], bounds: screen)
        for path in gesture.paths {
            let total = W3CActionsBuilder.source(for: path).actions.reduce(0) { sum, action in
                switch action {
                case .pause(let ms), .move(_, let ms): return sum + ms
                case .down, .up: return sum
                }
            }
            XCTAssertEqual(total, path.upMs, "finger \(path.id)")
        }
    }
}
