// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that InputSimulation refuses every other pointing operation while a touch is held.
// ABOUTME: Also covers InputSimulation.touch routing, live-window moves, and the escape skipped during a hold.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

final class TouchHeldRefusalTests: XCTestCase {

    private var bridge: StubBridge!
    private var poster: RecordingTouchPoster!
    private var session: TouchSession!
    private var input: InputSimulation!

    override func setUp() {
        super.setUp()
        bridge = StubBridge()
        // Not running: if a refusal were ever missing, the operation stops at
        // the state check instead of clicking on the Mac running the tests.
        bridge.state = .notRunning
        poster = RecordingTouchPoster()
        session = TouchSession(poster: poster)
        input = InputSimulation(bridge: bridge, layoutSubstitution: [:], touchSession: session)
    }

    override func tearDown() {
        _ = session.cancel()
        super.tearDown()
    }

    private func hold() {
        let window = WindowInfo(windowID: 1, position: .zero,
                                size: CGSize(width: 410, height: 898), pid: 1)
        _ = session.begin(at: CGPoint(x: 10, y: 20), window: window, targetPID: nil,
                          restorePoint: nil)
    }

    private func assertRefused(_ error: String?, tool: String, file: StaticString = #filePath,
                               line: UInt = #line) {
        guard let error else {
            return XCTFail("\(tool) must refuse while a touch is held", file: file, line: line)
        }
        XCTAssertTrue(error.contains("touch(action:\"cancel\")"), error, file: file, line: line)
        XCTAssertTrue(error.contains(tool), error, file: file, line: line)
    }

    func testEveryPointingOperationRefusesWhileHeld() {
        hold()
        assertRefused(input.tap(x: 1, y: 1), tool: "tap")
        assertRefused(input.swipe(fromX: 1, fromY: 1, toX: 2, toY: 2), tool: "swipe")
        assertRefused(input.drag(fromX: 1, fromY: 1, toX: 2, toY: 2), tool: "drag")
        assertRefused(input.longPress(x: 1, y: 1), tool: "longPress")
        assertRefused(input.doubleTap(x: 1, y: 1), tool: "doubleTap")
        XCTAssertTrue(session.isHeld, "a refusal must leave the held contact alone")
    }

    func testPointingProceedsToStateCheckWhenIdle() {
        let error = input.tap(x: 1, y: 1)
        XCTAssertEqual(error, "Target 'iphone' is not running. Launch iPhone Mirroring first.")
    }

    func testHeldTouchSkipsPausedSessionEscapeClick() {
        bridge.state = .paused
        bridge.connectOnResume = true
        hold()
        XCTAssertNotNil(input.ensureConnected(tag: "test"))
        XCTAssertEqual(bridge.state, .paused, "no escape plugin may run while a touch is held")
    }

    func testBeginThroughInputWhileHeldIsAlreadyHeld() {
        hold()
        XCTAssertEqual(input.touch(.begin(x: 50, y: 50)),
                       .failure(.alreadyHeld(at: CGPoint(x: 10, y: 20))))
    }

    func testBeginThroughInputReportsTargetState() {
        XCTAssertEqual(input.touch(.begin(x: 50, y: 50)),
                       .failure(.rejected("Target 'iphone' is not running. Launch iPhone Mirroring first.")))
        XCTAssertFalse(session.isHeld)
    }

    func testMoveOutsideHeldWindowIsRejectedAndContactStays() {
        hold()
        guard case .failure(.rejected(let message)) = input.touch(.move(x: 900, y: 20, durationMs: 10)) else {
            return XCTFail("a move outside the window must be rejected")
        }
        XCTAssertTrue(message.contains("outside"))
        XCTAssertTrue(session.isHeld)
    }

    func testMoveAfterRotationReleasesInsteadOfUsingTheStaleFrame() {
        hold()
        // The iPhone rotated: the live window is landscape at a new origin.
        bridge.windowInfo = WindowInfo(windowID: 1, position: CGPoint(x: 1040, y: 347),
                                       size: CGSize(width: 868, height: 440), pid: 1)
        guard case .failure(.windowChanged(let change)) = input.touch(.move(x: 600, y: 200, durationMs: 10)) else {
            return XCTFail("a move after a rotation must release the contact, not post a stale point")
        }
        XCTAssertEqual(change.liveSize, CGSize(width: 868, height: 440))
        XCTAssertFalse(session.isHeld)
        XCTAssertFalse(poster.events.contains { if case .move = $0 { return true } else { return false } })
    }

    func testMoveIsBoundsCheckedAndPlacedAgainstTheLiveOrigin() {
        hold()
        bridge.windowInfo = WindowInfo(windowID: 1, position: CGPoint(x: 300, y: 40),
                                       size: CGSize(width: 410, height: 898), pid: 1)
        guard case .failure(.rejected(let message)) = input.touch(.move(x: 500, y: 20, durationMs: 10)) else {
            return XCTFail("a move outside the live window must be rejected")
        }
        XCTAssertTrue(message.contains("outside"))
        XCTAssertEqual(input.touch(.move(x: 30, y: 40, durationMs: 10)),
                       .success(.moved(to: CGPoint(x: 30, y: 40))))
        XCTAssertEqual(poster.events.last,
                       .move(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 330, y: 80), durationMs: 10))
    }

    func testBeginOnAConnectedTargetPressesAtTheWindowOffsetPoint() {
        bridge.state = .connected
        // Not running as a process: focusing only calls the stub's activate(),
        // so nothing on the Mac running the tests is brought forward.
        bridge.processRunning = false
        bridge.windowInfo = WindowInfo(windowID: 1, position: CGPoint(x: 100, y: 200),
                                       size: CGSize(width: 410, height: 898), pid: 1)
        XCTAssertEqual(input.touch(.begin(x: 30, y: 40)), .success(.began(at: CGPoint(x: 30, y: 40))))
        XCTAssertEqual(poster.events.first, .engage(targetPID: nil))
        XCTAssertEqual(poster.events.dropFirst().first, .press(CGPoint(x: 130, y: 240)))
        XCTAssertEqual(session.heldPosition?.window.position, CGPoint(x: 100, y: 200))
    }

    func testMoveEndCancelRouteToSession() {
        hold()
        XCTAssertEqual(input.touch(.move(x: 30, y: 40, durationMs: 5)),
                       .success(.moved(to: CGPoint(x: 30, y: 40))))
        XCTAssertEqual(input.touch(.end), .success(.ended(at: CGPoint(x: 30, y: 40))))
        XCTAssertEqual(input.touch(.cancel), .success(.cancelled(releasedAt: nil)))
        XCTAssertEqual(input.touch(.end), .failure(.notHeld(lastRelease: nil)))
    }
}
