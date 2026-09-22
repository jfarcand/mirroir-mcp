// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the persistent touch contact: state machine, cancel, watchdog, live window, move bounds.
// ABOUTME: Drives TouchSession and InputSimulation through a recording TouchContactPosting fake.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

/// Records every touch primitive instead of posting CGEvents: a real post
/// would press the left button of the Mac running the tests.
final class RecordingTouchPoster: TouchContactPosting, @unchecked Sendable {
    enum Event: Equatable {
        case engage(targetPID: pid_t?)
        case disengage(engaged: Bool)
        case press(CGPoint)
        case move(from: CGPoint, to: CGPoint, durationMs: Int)
        case release(CGPoint)
        case warp(CGPoint)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    var pressSucceeds = true
    var releaseSucceeds = true
    var engageResult = true
    var location = CGPoint(x: 7, y: 9)
    /// Runs inside `move`, while its frames would be posting.
    var duringMove: (@Sendable () -> Void)?

    var events: [Event] { lock.withLock { recorded } }

    private func record(_ event: Event) { lock.withLock { recorded.append(event) } }

    func engagePointer(targetPID: pid_t?) -> Bool {
        record(.engage(targetPID: targetPID))
        return engageResult
    }
    func disengagePointer(_ engaged: Bool) { record(.disengage(engaged: engaged)) }
    func press(at point: CGPoint, targetPID: pid_t?) -> Bool {
        record(.press(point))
        return pressSucceeds
    }
    func move(from start: CGPoint, to end: CGPoint, durationMs: Int, targetPID: pid_t?) -> Bool {
        record(.move(from: start, to: end, durationMs: durationMs))
        duringMove?()
        return true
    }
    func release(at point: CGPoint, targetPID: pid_t?) -> Bool {
        record(.release(point))
        return releaseSucceeds
    }
    func pointerLocation() -> CGPoint { location }
    func warpPointer(to point: CGPoint) { record(.warp(point)) }
}

final class TouchSessionTests: XCTestCase {

    private let window = WindowInfo(
        windowID: 1, position: CGPoint(x: 100, y: 200),
        size: CGSize(width: 410, height: 898), pid: 1)

    private func makeSession(
        timeout: TimeInterval = TouchSession.defaultInactivityTimeout
    ) -> (TouchSession, RecordingTouchPoster) {
        let poster = RecordingTouchPoster()
        return (TouchSession(poster: poster, inactivityTimeout: timeout), poster)
    }

    private func begin(_ session: TouchSession, x: Double = 10, y: Double = 20,
                       restorePoint: CGPoint? = nil) -> Result<TouchOutcome, TouchSessionError> {
        session.begin(at: CGPoint(x: x, y: y), window: window, targetPID: nil,
                      restorePoint: restorePoint)
    }

    // MARK: - State machine

    func testBeginMoveEndPostsDownDraggedUpAtScreenPoints() {
        let (session, poster) = makeSession()
        XCTAssertEqual(begin(session), .success(.began(at: CGPoint(x: 10, y: 20))))
        XCTAssertTrue(session.isHeld)
        XCTAssertEqual(session.move(to: CGPoint(x: 50, y: 60), durationMs: 40, liveWindow: window),
                       .success(.moved(to: CGPoint(x: 50, y: 60))))
        XCTAssertEqual(session.end(), .success(.ended(at: CGPoint(x: 50, y: 60))))
        XCTAssertFalse(session.isHeld)
        XCTAssertEqual(poster.events, [
            .engage(targetPID: nil),
            .press(CGPoint(x: 110, y: 220)),
            .move(from: CGPoint(x: 110, y: 220), to: CGPoint(x: 150, y: 260), durationMs: 40),
            .release(CGPoint(x: 150, y: 260)),
            .disengage(engaged: true),
        ])
    }

    func testBeginWhileHeldIsRefusedWithoutPosting() {
        let (session, poster) = makeSession()
        _ = begin(session)
        let before = poster.events
        XCTAssertEqual(begin(session, x: 30, y: 40),
                       .failure(.alreadyHeld(at: CGPoint(x: 10, y: 20))))
        XCTAssertEqual(poster.events, before)
        _ = session.cancel()
    }

    func testMoveAndEndWhileIdleAreRefused() {
        let (session, poster) = makeSession()
        XCTAssertEqual(session.move(to: CGPoint(x: 1, y: 1), durationMs: 10, liveWindow: window),
                       .failure(.notHeld(lastRelease: nil)))
        XCTAssertEqual(session.end(), .failure(.notHeld(lastRelease: nil)))
        XCTAssertTrue(poster.events.isEmpty)
    }

    func testFailedPressLeavesSessionIdleAndPointerRestored() {
        let (session, poster) = makeSession()
        poster.pressSucceeds = false
        XCTAssertEqual(begin(session), .failure(.eventPostFailed(action: "begin")))
        XCTAssertFalse(session.isHeld)
        XCTAssertEqual(poster.events.last, .disengage(engaged: true))
    }

    func testEndRestoresPreservedPointer() {
        let (session, poster) = makeSession()
        _ = begin(session, restorePoint: CGPoint(x: 3, y: 4))
        _ = session.end()
        XCTAssertEqual(poster.events.last, .warp(CGPoint(x: 3, y: 4)))
    }

    // MARK: - Cancel

    func testCancelWhileHeldReleasesAtContact() {
        let (session, poster) = makeSession()
        _ = begin(session)
        XCTAssertEqual(session.cancel(), .success(.cancelled(releasedAt: CGPoint(x: 10, y: 20))))
        XCTAssertFalse(session.isHeld)
        XCTAssertTrue(poster.events.contains(.release(CGPoint(x: 110, y: 220))))
        XCTAssertEqual(poster.events.last, .disengage(engaged: true))
    }

    func testCancelIsIdempotentAndAlwaysPostsButtonUp() {
        let (session, poster) = makeSession()
        _ = begin(session)
        _ = session.cancel()
        XCTAssertEqual(session.cancel(), .success(.cancelled(releasedAt: nil)))
        XCTAssertEqual(session.cancel(), .success(.cancelled(releasedAt: nil)))
        let releases = poster.events.filter {
            if case .release = $0 { return true } else { return false }
        }
        XCTAssertEqual(releases, [
            .release(CGPoint(x: 110, y: 220)),
            .release(poster.location),
            .release(poster.location),
        ])
        // The idle cancels never touch the cursor: only the held contact engaged it.
        XCTAssertEqual(poster.events.filter { $0 == .disengage(engaged: true) }.count, 1)
    }

    func testCancelReportsFailedButtonUp() {
        let (session, poster) = makeSession()
        poster.releaseSucceeds = false
        XCTAssertEqual(session.cancel(), .failure(.eventPostFailed(action: "cancel")))
    }

    // MARK: - Watchdog

    func testWatchdogReleasesIdleContact() {
        let (session, poster) = makeSession(timeout: 0.2)
        _ = begin(session)
        XCTAssertTrue(waitUntil(timeout: 3) { !session.isHeld })
        XCTAssertTrue(poster.events.contains(.release(CGPoint(x: 110, y: 220))))
        XCTAssertEqual(poster.events.last, .disengage(engaged: true))
        guard case .failure(.notHeld(let reason?)) = session.end() else {
            return XCTFail("end after the watchdog must report why the touch was released")
        }
        XCTAssertTrue(reason.contains("watchdog"))
    }

    func testMoveKeepsContactAliveThroughWatchdog() {
        // Moves every 0.1s against a 1s timeout: a sleep would have to overrun
        // by 0.9s for the watchdog to fire, while the 1.6s span still covers
        // more than one full timeout.
        let (session, _) = makeSession(timeout: 1.0)
        _ = begin(session)
        for _ in 0..<16 {
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertEqual(session.move(to: CGPoint(x: 11, y: 21), durationMs: 1, liveWindow: window),
                           .success(.moved(to: CGPoint(x: 11, y: 21))))
        }
        XCTAssertTrue(session.isHeld)
        XCTAssertEqual(session.end(), .success(.ended(at: CGPoint(x: 11, y: 21))))
    }

    func testBeginAfterWatchdogReleaseStartsFresh() {
        let (session, _) = makeSession(timeout: 0.2)
        _ = begin(session)
        XCTAssertTrue(waitUntil(timeout: 3) { !session.isHeld })
        XCTAssertEqual(begin(session, x: 5, y: 6), .success(.began(at: CGPoint(x: 5, y: 6))))
        XCTAssertEqual(session.end(), .success(.ended(at: CGPoint(x: 5, y: 6))))
    }

    // MARK: - Live window

    func testMoveFollowsAWindowThatMovedWithoutResizing() {
        let (session, poster) = makeSession()
        _ = begin(session)
        let moved = WindowInfo(windowID: 1, position: CGPoint(x: 400, y: 50),
                               size: window.size, pid: 1)
        XCTAssertEqual(session.move(to: CGPoint(x: 30, y: 40), durationMs: 20, liveWindow: moved),
                       .success(.moved(to: CGPoint(x: 30, y: 40))))
        XCTAssertEqual(session.heldPosition?.window.position, moved.position)
        _ = session.end()
        XCTAssertEqual(poster.events, [
            .engage(targetPID: nil),
            .press(CGPoint(x: 110, y: 220)),
            // From where the button is, to the point in the window's new frame.
            .move(from: CGPoint(x: 110, y: 220), to: CGPoint(x: 430, y: 90), durationMs: 20),
            .release(CGPoint(x: 430, y: 90)),
            .disengage(engaged: true),
        ])
    }

    func testRotationReleasesTheContactAndRefusesTheMove() {
        let (session, poster) = makeSession()
        _ = begin(session)
        let landscape = WindowInfo(windowID: 1, position: CGPoint(x: 1040, y: 347),
                                   size: CGSize(width: 868, height: 440), pid: 1)
        let change = TouchWindowChange(held: window, live: landscape)
        XCTAssertEqual(session.move(to: CGPoint(x: 600, y: 200), durationMs: 20, liveWindow: landscape),
                       .failure(.windowChanged(change)))
        XCTAssertFalse(session.isHeld)
        XCTAssertFalse(poster.events.contains { if case .move = $0 { return true } else { return false } },
                       "nothing may be dragged across a changed coordinate space")
        XCTAssertTrue(poster.events.contains(.release(CGPoint(x: 110, y: 220))),
                      "the button comes up where it was last posted")
        XCTAssertTrue(change.description.contains("410x898 to 868x440"), change.description)
    }

    func testMissingWindowReleasesTheContact() {
        let (session, poster) = makeSession()
        _ = begin(session)
        XCTAssertEqual(session.move(to: CGPoint(x: 1, y: 1), durationMs: 20, liveWindow: nil),
                       .failure(.windowChanged(TouchWindowChange(held: window, live: nil))))
        XCTAssertFalse(session.isHeld)
        XCTAssertEqual(poster.events.last, .disengage(engaged: true))
    }

    func testMoveDurationOutsideBoundsIsRefusedWithoutPosting() {
        let (session, poster) = makeSession()
        _ = begin(session)
        let before = poster.events
        for duration in [0, TouchSession.maxMoveDurationMs + 1] {
            guard case .failure(.rejected(let message)) = session.move(
                to: CGPoint(x: 1, y: 1), durationMs: duration, liveWindow: window) else {
                return XCTFail("duration \(duration) must be refused")
            }
            XCTAssertTrue(message.contains("between"), message)
        }
        XCTAssertEqual(poster.events, before)
        XCTAssertTrue(session.isHeld)
        _ = session.cancel()
    }

    func testReleaseDuringAMoveDoesNotWaitForItsFrames() {
        let (session, poster) = makeSession()
        _ = begin(session)
        let released = expectation(description: "exit release completed while the move posted")
        poster.duringMove = {
            // An exit release on another thread while the move posts its frames.
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                session.releaseIfHeld(reason: "signal 15")
                done.signal()
            }
            if done.wait(timeout: .now() + 2) == .success { released.fulfill() }
        }
        XCTAssertEqual(session.move(to: CGPoint(x: 30, y: 40), durationMs: 20, liveWindow: window),
                       .failure(.notHeld(lastRelease: "signal 15")))
        wait(for: [released], timeout: 3)
        XCTAssertFalse(session.isHeld)
    }

    // MARK: - Shutdown

    func testReleaseIfHeldReleasesOnceAndReportsWhetherHeld() {
        let (session, poster) = makeSession()
        XCTAssertFalse(session.releaseIfHeld(reason: "test exit"))
        XCTAssertTrue(poster.events.isEmpty)
        _ = begin(session)
        XCTAssertTrue(session.releaseIfHeld(reason: "test exit"))
        XCTAssertFalse(session.isHeld)
        XCTAssertFalse(session.releaseIfHeld(reason: "test exit"))
        guard case .failure(.notHeld(let reason?)) = session.end() else {
            return XCTFail("end after a server release must report the reason")
        }
        XCTAssertEqual(reason, "test exit")
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }
}
