// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the exit-path release: a termination signal stops running playbacks, lifts the touch, then exits.
// ABOUTME: Also covers the typed window-list parsing and the one geometry tolerance every bridge shares.

import XCTest
import CoreGraphics
@testable import mirroir_mcp

final class HeldInputReleaseOnExitTests: XCTestCase {

    private let window = WindowInfo(windowID: 1, position: CGPoint(x: 100, y: 200),
                                    size: CGSize(width: 410, height: 898), pid: 1)

    func testTerminateReleasesTheTouchAndReturnsTheSignalStatus() {
        let poster = RecordingTouchPoster()
        let session = TouchSession(poster: poster)
        _ = session.begin(at: CGPoint(x: 10, y: 20), window: window, targetPID: nil,
                          restorePoint: nil)

        let status = HeldInputReleaseOnExit.terminate(signal: SIGTERM, session: session,
                                                      interruption: PlaybackInterruption())
        XCTAssertEqual(status, 128 + SIGTERM)
        XCTAssertFalse(session.isHeld)
        XCTAssertTrue(poster.events.contains(.release(CGPoint(x: 110, y: 220))))
        guard case .failure(.notHeld(let reason?)) = session.end() else {
            return XCTFail("the release must record the signal as its reason")
        }
        XCTAssertEqual(reason, "signal \(SIGTERM)")
    }

    func testTerminateWaitsForARunningHoldToReleaseItsKeys() throws {
        let interruption = PlaybackInterruption()
        let session = TouchSession(poster: RecordingTouchPoster())
        let keyPoster = RecordingHeldInputPoster()
        let request = try HeldKeysRequest.make(keyNames: ["w"], durationMs: 10_000, drag: nil).get()
        let plan = HeldKeysPlanner.plan(for: request, dragPath: nil)
        let started = DispatchSemaphore(value: 0)
        let finished = expectation(description: "hold returned")

        DispatchQueue.global().async {
            let outcome = HeldInputPlayback.play(
                plan, targetPID: nil, poster: PacedHeldInputPoster(recording: keyPoster, started: started),
                targetFocused: { true }, interruption: interruption)
            XCTAssertEqual(outcome, .interrupted)
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        let status = HeldInputReleaseOnExit.terminate(signal: SIGINT, session: session,
                                                      interruption: interruption)
        XCTAssertEqual(status, 128 + SIGINT)
        XCTAssertEqual(keyPoster.postedEvents.last, .keyUp(try XCTUnwrap(HeldKey.resolve("w")), flags: []),
                       "the key was released before terminate returned")
        wait(for: [finished], timeout: 2)
    }

    // MARK: - Window list

    func testWindowListEntryParsesTypedFields() {
        let raw: [String: Any] = [
            kCGWindowOwnerPID as String: pid_t(42),
            kCGWindowNumber as String: CGWindowID(7),
            kCGWindowName as String: "iPhone Mirroring",
            kCGWindowOwnerName as String: "iPhone Mirroring",
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: ["X": 1040, "Y": 347, "Width": CGFloat(868), "Height": 440],
        ]
        XCTAssertEqual(WindowListHelper.entry(from: raw), WindowListEntry(
            windowID: 7, ownerPID: 42, name: "iPhone Mirroring",
            bounds: CGRect(x: 1040, y: 347, width: 868, height: 440),
            ownerName: "iPhone Mirroring", layer: 0))
        XCTAssertNil(WindowListHelper.entry(from: [kCGWindowOwnerPID as String: pid_t(42)]))
    }

    func testFindWindowIDUsesTheSharedTolerance() {
        let entries = [WindowListEntry(windowID: 9, ownerPID: 5, name: nil,
                                       bounds: CGRect(x: 100, y: 200, width: 410, height: 898))]
        let near = WindowListHelper.geometryMatchTolerance - 1
        XCTAssertEqual(WindowListHelper.findWindowID(
            pid: 5, position: CGPoint(x: 100 + near, y: 200),
            size: CGSize(width: 410 - near, height: 898), in: entries), 9)
        XCTAssertNil(WindowListHelper.findWindowID(
            pid: 5, position: CGPoint(x: 100 + WindowListHelper.geometryMatchTolerance, y: 200),
            size: CGSize(width: 410, height: 898), in: entries))
        XCTAssertNil(WindowListHelper.findWindowID(
            pid: 6, position: CGPoint(x: 100, y: 200),
            size: CGSize(width: 410, height: 898), in: entries))
    }
}
