// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests gesture playback order through a recording poster, InputSimulation.gesture refusals,
// ABOUTME: the trackpad sender selection, and the CGEvent field stamping of the live gesture poster.

import XCTest
import CoreGraphics
@testable import mirroir_mcp

/// Records every gesture event instead of posting it, so tests see the exact
/// order and never move the pointer of the Mac running them.
final class RecordingGesturePoster: GestureEventPosting, @unchecked Sendable {
    enum Call: Equatable {
        case engage(targetPID: pid_t?)
        case disengage(engaged: Bool)
        case post(GestureEvent, centre: CGPoint, senderID: UInt64)
        case pause(UInt32)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    /// Number of posts that succeed before every later post fails; nil = all succeed.
    var postsBeforeFailure: Int?

    var calls: [Call] { lock.withLock { recorded } }
    var postedEvents: [GestureEvent] {
        calls.compactMap { call -> GestureEvent? in
            if case .post(let event, _, _) = call { return event }
            return nil
        }
    }

    func engagePointer(targetPID: pid_t?) -> Bool {
        lock.withLock { recorded.append(.engage(targetPID: targetPID)) }
        return true
    }
    func disengagePointer(_ engaged: Bool) {
        lock.withLock { recorded.append(.disengage(engaged: engaged)) }
    }
    func post(_ event: GestureEvent, at centre: CGPoint, senderID: UInt64, targetPID: pid_t?) -> Bool {
        lock.withLock {
            if let remaining = postsBeforeFailure {
                guard remaining > 0 else { return false }
                postsBeforeFailure = remaining - 1
            }
            recorded.append(.post(event, centre: centre, senderID: senderID))
            return true
        }
    }
    func pause(microseconds: UInt32) {
        lock.withLock { recorded.append(.pause(microseconds)) }
    }
}

/// Answers a fixed trackpad sender ID (nil = a Mac without a trackpad).
struct FixedSenderResolver: MultitouchSenderResolving {
    let senderID: UInt64?
    func multitouchSenderID() -> UInt64? { senderID }
}

final class GesturePlaybackTests: XCTestCase {

    private let centre = CGPoint(x: 120, y: 340)
    private let senderID: UInt64 = 4_294_969_663

    // MARK: - Playback order

    func testPlaybackPostsEveryStepInOrderWithinOnePointerEngagement() {
        let poster = RecordingGesturePoster()
        let steps = GesturePlanner.steps(for: .pinch(scale: 2), durationMs: 200)
        XCTAssertTrue(GesturePlayback.play(steps, at: centre, senderID: senderID,
                                           targetPID: nil, poster: poster))

        let calls = poster.calls
        XCTAssertEqual(calls.first, .engage(targetPID: nil))
        XCTAssertEqual(calls.last, .disengage(engaged: true))
        XCTAssertEqual(poster.postedEvents, steps.flatMap(\.events))
        XCTAssertEqual(poster.postedEvents.first, .pointerMove,
                       "the pointer move sets the centre before the gesture opens")
        for case .post(_, let postedCentre, let postedSender) in calls {
            XCTAssertEqual(postedCentre, centre)
            XCTAssertEqual(postedSender, senderID)
        }
        let phases = poster.postedEvents.compactMap { event -> GesturePhase? in
            if case .gesture(_, let phase, _) = event { return phase }
            return nil
        }
        XCTAssertEqual(phases.first, .began)
        XCTAssertEqual(phases.last, .ended)
        XCTAssertTrue(phases.dropFirst().dropLast().allSatisfy { $0 == .changed })
    }

    func testFailureSkipsTheRemainingFrames() {
        let poster = RecordingGesturePoster()
        // pointer move + container + began + container succeed, then every
        // post fails: no changed frame follows and the call reports failure.
        poster.postsBeforeFailure = 4
        let steps = GesturePlanner.steps(for: .rotate(degrees: 45), durationMs: 200)
        let delivered = GesturePlayback.play(steps, at: centre, senderID: senderID,
                                             targetPID: nil, poster: poster)
        XCTAssertFalse(delivered)
        XCTAssertEqual(poster.postedEvents,
                       [.pointerMove, .container, .gesture(.rotate, .began, delta: 0), .container])
        XCTAssertEqual(poster.calls.last, .disengage(engaged: true))
    }

    func testClosingIsAttemptedAfterAMidGestureFailure() {
        let poster = ClosingOnlyPoster(failingPostIndex: 5)
        let steps = GesturePlanner.steps(for: .pinch(scale: 0.5), durationMs: 200)
        XCTAssertFalse(GesturePlayback.play(steps, at: centre, senderID: senderID,
                                            targetPID: nil, poster: poster))
        XCTAssertEqual(poster.posted.suffix(2), [.container, .gesture(.zoom, .ended, delta: 0)],
                       "an opened gesture must always receive its ended event")
    }

    func testEndedIsPostedEvenWhenItsContainerFails() {
        // Fail the closing container only: the ended event must still go out.
        let steps = GesturePlanner.steps(for: .pinch(scale: 2), durationMs: 200)
        let closingContainerIndex = steps.dropLast().flatMap(\.events).count
        let poster = ClosingOnlyPoster(failingPostIndex: closingContainerIndex)
        XCTAssertFalse(GesturePlayback.play(steps, at: centre, senderID: senderID,
                                            targetPID: nil, poster: poster,
                                            interruption: PlaybackInterruption()))
        XCTAssertEqual(poster.posted.last, .gesture(.zoom, .ended, delta: 0))
    }

    func testInterruptedGestureStillCloses() {
        let interruption = PlaybackInterruption()
        let poster = InterruptingGesturePoster(interruption: interruption, afterPosts: 5)
        let steps = GesturePlanner.steps(for: .rotate(degrees: 90), durationMs: 500)
        XCTAssertFalse(GesturePlayback.play(steps, at: centre, senderID: senderID,
                                            targetPID: nil, poster: poster, interruption: interruption))
        XCTAssertEqual(poster.posted.suffix(2), [.container, .gesture(.rotate, .ended, delta: 0)])
        XCTAssertLessThan(poster.posted.count, steps.flatMap(\.events).count,
                          "the remaining frames are skipped")
    }

    func testFailureBeforeOpeningPostsNoClosing() {
        let poster = RecordingGesturePoster()
        poster.postsBeforeFailure = 0
        let steps = GesturePlanner.steps(for: .pinch(scale: 2), durationMs: 200)
        XCTAssertFalse(GesturePlayback.play(steps, at: centre, senderID: senderID,
                                            targetPID: nil, poster: poster))
        XCTAssertTrue(poster.postedEvents.isEmpty)
    }

    // MARK: - InputSimulation.gesture

    private func makeInput(senderID: UInt64?, touchSession: TouchSession? = nil,
                           poster: RecordingGesturePoster) -> (InputSimulation, StubBridge) {
        let bridge = StubBridge()
        // Not running: a missing refusal stops at the state check instead of
        // activating a window on the Mac running the tests.
        bridge.state = .notRunning
        let device = GestureDevice(poster: poster,
                                   senderResolver: FixedSenderResolver(senderID: senderID))
        let input = InputSimulation(bridge: bridge, layoutSubstitution: [:],
                                    touchSession: touchSession ?? TouchSession(poster: RecordingTouchPoster()),
                                    gestureDevice: device)
        return (input, bridge)
    }

    private let pinchRequest = GestureRequest(x: 50, y: 60, gesture: .pinch(scale: 2), durationMs: 200)

    func testMissingTrackpadIsAClearErrorAndPostsNothing() {
        let poster = RecordingGesturePoster()
        let (input, _) = makeInput(senderID: nil, poster: poster)
        let error = input.gesture(pinchRequest)
        XCTAssertEqual(error, InputSimulation.noTrackpadMessage(tool: "pinch"))
        XCTAssertTrue(error?.contains("Magic Trackpad") ?? false)
        XCTAssertTrue(poster.calls.isEmpty)
    }

    func testGestureRefusesWhileATouchIsHeld() {
        let session = TouchSession(poster: RecordingTouchPoster())
        defer { _ = session.cancel() }
        _ = session.begin(at: CGPoint(x: 10, y: 20),
                          window: WindowInfo(windowID: 1, position: .zero,
                                             size: CGSize(width: 410, height: 898), pid: 1),
                          targetPID: nil, restorePoint: nil)
        let poster = RecordingGesturePoster()
        let (input, _) = makeInput(senderID: senderID, touchSession: session, poster: poster)

        let rotate = GestureRequest(x: 50, y: 60, gesture: .rotate(degrees: 30), durationMs: 200)
        let error = input.gesture(rotate)
        XCTAssertTrue(error?.contains("rotate") ?? false, error ?? "nil")
        XCTAssertTrue(error?.contains("touch(action:\"cancel\")") ?? false, error ?? "nil")
        XCTAssertTrue(poster.calls.isEmpty)
        XCTAssertTrue(session.isHeld, "a refusal must leave the held contact alone")
    }

    func testGestureReportsTargetStateWhenIdle() {
        let poster = RecordingGesturePoster()
        let (input, _) = makeInput(senderID: senderID, poster: poster)
        XCTAssertEqual(input.gesture(pinchRequest),
                       "Target 'iphone' is not running. Launch iPhone Mirroring first.")
        XCTAssertTrue(poster.calls.isEmpty)
    }

    func testGestureOnAConnectedTargetIsCentredAtTheWindowOffsetPoint() {
        let poster = RecordingGesturePoster()
        let (input, bridge) = makeInput(senderID: senderID, poster: poster)
        bridge.state = .connected
        // Not running as a process: focusing only calls the stub's activate(),
        // so nothing on the Mac running the tests is brought forward.
        bridge.processRunning = false
        bridge.windowInfo = WindowInfo(windowID: 1, position: CGPoint(x: 100, y: 200),
                                       size: CGSize(width: 410, height: 898), pid: 1)
        XCTAssertNil(input.gesture(pinchRequest))
        let centres = poster.calls.compactMap { call -> CGPoint? in
            if case .post(_, let centre, _) = call { return centre }
            return nil
        }
        XCTAssertFalse(centres.isEmpty)
        XCTAssertTrue(centres.allSatisfy { $0 == CGPoint(x: 150, y: 260) }, "\(Set(centres.map(\.x)))")
    }

    // MARK: - Sender selection

    func testSelectorPrefersBuiltInDigitizer() {
        let external = MultitouchServiceCandidate(registryID: 7, builtIn: false, usagePages: [1, 0x0D])
        let builtIn = MultitouchServiceCandidate(registryID: 9, builtIn: true, usagePages: [0x0D])
        XCTAssertEqual(MultitouchSenderSelector.select(from: [external, builtIn]), 9)
        XCTAssertEqual(MultitouchSenderSelector.select(from: [external]), 7)
    }

    func testSelectorIgnoresNonDigitizersAndEmptyRegistry() {
        let mouse = MultitouchServiceCandidate(registryID: 3, builtIn: true, usagePages: [1])
        XCTAssertNil(MultitouchSenderSelector.select(from: [mouse]))
        XCTAssertNil(MultitouchSenderSelector.select(from: []))
    }

    // MARK: - CGEvent stamping

    private func field(_ event: CGEvent, _ raw: UInt32) -> Int64 {
        guard let cgField = CGEventField(rawValue: raw) else { return .min }
        return event.getIntegerValueField(cgField)
    }

    func testSubGestureEventCarriesTheMeasuredFields() throws {
        let delta = 0.0725
        let event = try XCTUnwrap(CGEventGesturePoster.makeEvent(
            .gesture(.zoom, .changed, delta: delta), at: centre, senderID: senderID))
        XCTAssertEqual(event.type.rawValue, CGEventGesturePoster.gestureEventType)
        XCTAssertEqual(field(event, CGEventGesturePoster.senderIDField), Int64(senderID))
        XCTAssertEqual(field(event, CGEventGesturePoster.trackpadMarkerField), 1)
        XCTAssertEqual(field(event, CGEventGesturePoster.subtypeField), GestureKind.zoom.rawValue)
        XCTAssertEqual(field(event, CGEventGesturePoster.phaseField), GesturePhase.changed.rawValue)
        for raw in CGEventGesturePoster.deltaDoubleFields {
            let cgField = try XCTUnwrap(CGEventField(rawValue: raw))
            // CGEvent keeps double fields at 32-bit float precision.
            XCTAssertEqual(event.getDoubleValueField(cgField), Double(Float(delta)), accuracy: 1e-12)
        }
        for raw in CGEventGesturePoster.deltaFloatBitsFields {
            XCTAssertEqual(field(event, raw), Int64(Float(delta).bitPattern))
        }
    }

    func testContainerAndPointerMoveCarryTheSenderOnly() throws {
        let container = try XCTUnwrap(CGEventGesturePoster.makeEvent(.container, at: centre,
                                                                      senderID: senderID))
        XCTAssertEqual(container.type.rawValue, CGEventGesturePoster.gestureEventType)
        XCTAssertEqual(field(container, CGEventGesturePoster.senderIDField), Int64(senderID))
        XCTAssertEqual(field(container, CGEventGesturePoster.subtypeField), 0)
        XCTAssertEqual(field(container, CGEventGesturePoster.trackpadMarkerField),
                       CGEventGesturePoster.trackpadMarkerValue)
        XCTAssertEqual(field(container, CGEventGesturePoster.phaseField), 0,
                       "no phase may leak onto the bare container")

        let move = try XCTUnwrap(CGEventGesturePoster.makeEvent(.pointerMove, at: centre,
                                                                 senderID: senderID))
        XCTAssertEqual(move.type, .mouseMoved)
        XCTAssertEqual(move.location, centre)
        XCTAssertEqual(field(move, CGEventGesturePoster.senderIDField), Int64(senderID))
    }
}

/// Fails exactly one post (by index) and lets every other through, to show an
/// opened gesture still receives its closing events after a mid-gesture failure.
private final class ClosingOnlyPoster: GestureEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private let failingPostIndex: Int
    private var attempts = 0
    private var recorded: [GestureEvent] = []

    init(failingPostIndex: Int) { self.failingPostIndex = failingPostIndex }

    var posted: [GestureEvent] { lock.withLock { recorded } }

    func engagePointer(targetPID: pid_t?) -> Bool { false }
    func disengagePointer(_ engaged: Bool) {}
    func post(_ event: GestureEvent, at centre: CGPoint, senderID: UInt64, targetPID: pid_t?) -> Bool {
        lock.withLock {
            defer { attempts += 1 }
            guard attempts != failingPostIndex else { return false }
            recorded.append(event)
            return true
        }
    }
    func pause(microseconds: UInt32) {}
}

/// Records gesture events and marks shutdown after `afterPosts` posts, to
/// show an interrupted gesture skips its frames yet still closes.
private final class InterruptingGesturePoster: GestureEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private let interruption: PlaybackInterruption
    private let afterPosts: Int
    private var recorded: [GestureEvent] = []

    init(interruption: PlaybackInterruption, afterPosts: Int) {
        self.interruption = interruption
        self.afterPosts = afterPosts
    }

    var posted: [GestureEvent] { lock.withLock { recorded } }

    func engagePointer(targetPID: pid_t?) -> Bool { false }
    func disengagePointer(_ engaged: Bool) {}
    func post(_ event: GestureEvent, at centre: CGPoint, senderID: UInt64, targetPID: pid_t?) -> Bool {
        let count = lock.withLock { () -> Int in
            recorded.append(event)
            return recorded.count
        }
        if count == afterPosts {
            // interruptAndWait blocks until the playback ends, so it runs off
            // the playback's thread, as the signal handler does.
            let interruption = self.interruption
            DispatchQueue.global().async { interruption.interruptAndWait(timeout: 2) }
            while !interruption.isInterrupted { usleep(1_000) }
        }
        return true
    }
    func pause(microseconds: UInt32) {}
}
