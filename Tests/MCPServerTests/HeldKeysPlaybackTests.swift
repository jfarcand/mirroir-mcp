// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests hold_keys key resolution, request bounds, planner timing and interpolation, and playback.
// ABOUTME: A recording poster checks pairing, reverse release, release on error/focus loss/shutdown, refusals.

import XCTest
import CoreGraphics
@testable import mirroir_mcp

/// Records every hold event instead of posting it, so tests see the exact
/// order and never press keys or move the pointer of the Mac running them.
final class RecordingHeldInputPoster: HeldInputPosting, @unchecked Sendable {
    enum Call: Equatable {
        case engage(targetPID: pid_t?)
        case disengage(engaged: Bool)
        case post(HeldInputEvent)
        case pause(UInt32)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    /// Events for which the post fails (nothing is recorded for them).
    var failWhen: (@Sendable (HeldInputEvent) -> Bool)?

    var calls: [Call] { lock.withLock { recorded } }
    var postedEvents: [HeldInputEvent] {
        calls.compactMap { call -> HeldInputEvent? in
            if case .post(let event) = call { return event }
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
    func post(_ event: HeldInputEvent, targetPID: pid_t?) -> Bool {
        lock.withLock {
            if let failWhen, failWhen(event) { return false }
            recorded.append(.post(event))
            return true
        }
    }
    func pause(microseconds: UInt32) {
        lock.withLock { recorded.append(.pause(microseconds)) }
    }
}

final class HeldKeysPlaybackTests: XCTestCase {

    private func key(_ name: String) throws -> HeldKey {
        try XCTUnwrap(HeldKey.resolve(name), "\(name) should resolve")
    }

    private func request(_ names: [String], durationMs: Int = 1_000,
                         drag: HeldKeysDrag? = nil) throws -> HeldKeysRequest {
        try HeldKeysRequest.make(keyNames: names, durationMs: durationMs, drag: drag).get()
    }

    private let from = CGPoint(x: 100, y: 200)
    private let to = CGPoint(x: 300, y: 260)

    // MARK: - Key resolution and bounds

    func testKeyNamesResolveToKeycodes() throws {
        XCTAssertEqual(try key("W"), HeldKey(name: "w", keycode: 13, modifier: nil))
        XCTAssertEqual(try key("space").keycode, 49)
        XCTAssertEqual(try key("up").keycode, 126)
        XCTAssertEqual(try key("shift"), HeldKey(name: "shift", keycode: 0x38, modifier: .maskShift))
        XCTAssertNil(HeldKey.resolve("!"), "a shifted character is not one key")
        XCTAssertNil(HeldKey.resolve("\u{1F3AE}"))
        XCTAssertNil(HeldKey.resolve("ctrl"))
    }

    func testRequestBounds() {
        func error(_ names: [String], _ durationMs: Int = 1_000,
                   _ drag: HeldKeysDrag? = nil) -> String? {
            if case .failure(let failure) = HeldKeysRequest.make(
                keyNames: names, durationMs: durationMs, drag: drag) { return failure.message }
            return nil
        }
        XCTAssertNotNil(error([]))
        XCTAssertNotNil(error(Array(repeating: "a", count: HeldKeysRequest.maxKeys + 1)))
        XCTAssertNil(error(["a", "s", "d", "w", "space", "shift"]))
        XCTAssertTrue(error(["w", "\u{00E9}"])?.contains("'\u{00E9}'") ?? false, "names the unmappable key")
        XCTAssertTrue(error(["w", "W"])?.contains("more than once") ?? false)
        XCTAssertNotNil(error(["w"], HeldKeysRequest.minDurationMs - 1))
        XCTAssertNotNil(error(["w"], HeldKeysRequest.maxDurationMs + 1))
        XCTAssertNil(error(["w"], HeldKeysRequest.maxDurationMs))
        XCTAssertNotNil(error(["w"], 1_000, HeldKeysDrag(fromX: .nan, fromY: 0, toX: 1, toY: 1,
                                                         button: .left)))
    }

    // MARK: - Planner

    func testPressesInOrderAndReleasesInReverse() throws {
        let plan = HeldKeysPlanner.plan(for: try request(["shift", "w"]), dragPath: nil)
        let shift = try key("shift"), w = try key("w")
        XCTAssertEqual(plan.presses.flatMap(\.events), [
            .modifierDown(shift, flags: .maskShift),
            .keyDown(w, flags: .maskShift, isRepeat: false),
        ])
        XCTAssertEqual(HeldKeysPlanner.releases(for: plan.presses.flatMap(\.events), buttonPoint: .zero), [
            .keyUp(w, flags: .maskShift),
            .modifierUp(shift, flags: []),
        ])
    }

    func testAutoRepeatCountMatchesDuration() throws {
        let plan = HeldKeysPlanner.plan(for: try request(["w", "shift", "a"], durationMs: 1_000),
                                        dragPath: nil)
        let repeats = plan.frames.flatMap(\.events).filter {
            if case .keyDown(_, _, true) = $0 { return true } else { return false }
        }
        // 1000ms at a 50ms interval: a repeat at 50, 100, ... 950ms per plain
        // key; the modifier never repeats.
        let perKey = 1_000 / HeldKeysPlanner.keyRepeatIntervalMs - 1
        XCTAssertEqual(perKey, 19)
        XCTAssertEqual(repeats.count, perKey * 2)
        XCTAssertFalse(repeats.contains { if case .keyDown(let k, _, _) = $0 { return k.name == "shift" }
                                          return false })
        XCTAssertTrue(repeats.allSatisfy { if case .keyDown(_, .maskShift, true) = $0 { return true }
                                           return false }, "repeats carry the held modifiers")

        let frameUs = plan.frames.map(\.pauseAfterUs).reduce(0, +)
        let tolerance = UInt32(FramePacing.frameCount(durationMs: 1_000))
        XCTAssertEqual(Double(frameUs), 1_000_000, accuracy: Double(tolerance),
                       "frames span the whole duration")
    }

    func testDragInterpolatesFromStartToEndWithTheChosenButton() throws {
        let drag = HeldKeysDrag(fromX: 0, fromY: 0, toX: 1, toY: 1, button: .right)
        let plan = HeldKeysPlanner.plan(for: try request(["w"], durationMs: 500, drag: drag),
                                        dragPath: (from, to))
        XCTAssertEqual(plan.presses.last?.events, [.buttonDown(.right, at: from)])
        XCTAssertTrue(plan.holdsButton)
        let dragged = plan.frames.flatMap(\.events).compactMap { event -> CGPoint? in
            if case .buttonDragged(.right, let point) = event { return point }
            return nil
        }
        let frames = FramePacing.frameCount(durationMs: 500)
        XCTAssertEqual(dragged.count, frames)
        XCTAssertEqual(dragged.last, to)
        let first = try XCTUnwrap(dragged.first)
        XCTAssertEqual(first.x, from.x + (to.x - from.x) / CGFloat(frames), accuracy: 0.001)
        XCTAssertEqual(first.y, from.y + (to.y - from.y) / CGFloat(frames), accuracy: 0.001)
        XCTAssertFalse(plan.frames.flatMap(\.events).contains {
            if case .buttonDragged(.left, _) = $0 { return true } else { return false }
        })
    }

    // MARK: - Playback

    /// Play with the target always focused and a private interruption
    /// registry, so no test can mark the process-wide one as shutting down.
    private func play(_ plan: HeldInputPlan, _ poster: RecordingHeldInputPoster,
                      targetFocused: () -> Bool = { true },
                      interruption: PlaybackInterruption = PlaybackInterruption()) -> HeldInputOutcome {
        HeldInputPlayback.play(plan, targetPID: nil, poster: poster,
                               targetFocused: targetFocused, interruption: interruption)
    }

    func testPlaybackPairsEveryDownWithAnUpInReverseOrder() throws {
        let drag = HeldKeysDrag(fromX: 0, fromY: 0, toX: 1, toY: 1, button: .right)
        let plan = HeldKeysPlanner.plan(for: try request(["shift", "w"], durationMs: 200, drag: drag),
                                        dragPath: (from, to))
        let poster = RecordingHeldInputPoster()
        XCTAssertEqual(play(plan, poster), .delivered)

        XCTAssertEqual(poster.calls.first, .engage(targetPID: nil))
        XCTAssertEqual(poster.calls.last, .disengage(engaged: true))
        let posted = poster.postedEvents
        XCTAssertEqual(Array(posted.suffix(3)), [
            .buttonUp(.right, at: to),
            .keyUp(try key("w"), flags: .maskShift),
            .modifierUp(try key("shift"), flags: []),
        ])
        XCTAssertEqual(Array(posted.prefix(3)), [
            .modifierDown(try key("shift"), flags: .maskShift),
            .keyDown(try key("w"), flags: .maskShift, isRepeat: false),
            .buttonDown(.right, at: from),
        ])
    }

    func testKeysOnlyNeverEngagesThePointer() throws {
        let plan = HeldKeysPlanner.plan(for: try request(["w"], durationMs: 100), dragPath: nil)
        let poster = RecordingHeldInputPoster()
        XCTAssertEqual(play(plan, poster), .delivered)
        XCTAssertFalse(poster.calls.contains(.engage(targetPID: nil)))
        XCTAssertEqual(poster.calls.last, .disengage(engaged: false))
        XCTAssertEqual(poster.postedEvents.last, .keyUp(try key("w"), flags: []))
    }

    func testFailedPressReleasesOnlyWhatWentDown() throws {
        let drag = HeldKeysDrag(fromX: 0, fromY: 0, toX: 1, toY: 1, button: .left)
        let plan = HeldKeysPlanner.plan(for: try request(["w", "a"], drag: drag), dragPath: (from, to))
        let poster = RecordingHeldInputPoster()
        poster.failWhen = { if case .buttonDown = $0 { return true } else { return false } }

        XCTAssertEqual(play(plan, poster), .postFailed)
        XCTAssertEqual(poster.postedEvents, [
            .keyDown(try key("w"), flags: [], isRepeat: false),
            .keyDown(try key("a"), flags: [], isRepeat: false),
            .keyUp(try key("a"), flags: []),
            .keyUp(try key("w"), flags: []),
        ], "no frames after the failure, and the button that never went down is not released")
        XCTAssertEqual(poster.calls.last, .disengage(engaged: true))
    }

    func testFailedFrameReleasesTheButtonWhereItStopped() throws {
        let drag = HeldKeysDrag(fromX: 0, fromY: 0, toX: 1, toY: 1, button: .right)
        let plan = HeldKeysPlanner.plan(for: try request(["w"], durationMs: 500, drag: drag),
                                        dragPath: (from, to))
        let frames = CGFloat(FramePacing.frameCount(durationMs: 500))
        let t = CGFloat(3) / frames
        let stop = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        let poster = RecordingHeldInputPoster()
        poster.failWhen = { event in
            guard case .buttonDragged(_, let point) = event else { return false }
            return point.x > stop.x + 0.001
        }

        XCTAssertEqual(play(plan, poster), .postFailed)
        XCTAssertEqual(Array(poster.postedEvents.suffix(2)), [
            .buttonUp(.right, at: stop),
            .keyUp(try key("w"), flags: []),
        ])
    }

    func testEveryReleaseIsAttemptedWhenOneFails() throws {
        let plan = HeldKeysPlanner.plan(for: try request(["shift", "w", "a"], durationMs: 100),
                                        dragPath: nil)
        let poster = RecordingHeldInputPoster()
        let a = try key("a")
        poster.failWhen = { $0 == .keyUp(a, flags: .maskShift) }

        XCTAssertEqual(play(plan, poster), .postFailed)
        XCTAssertEqual(Array(poster.postedEvents.suffix(2)), [
            .keyUp(try key("w"), flags: .maskShift),
            .modifierUp(try key("shift"), flags: []),
        ])
    }

    func testFocusLossStopsRepeatsAndReleasesEverything() throws {
        let plan = HeldKeysPlanner.plan(for: try request(["command", "w"], durationMs: 1_000),
                                        dragPath: nil)
        let poster = RecordingHeldInputPoster()
        // Focused for the two presses and the first repeat, then another app takes focus.
        var checks = 0
        let outcome = play(plan, poster, targetFocused: {
            checks += 1
            return checks <= 3
        })
        XCTAssertEqual(outcome, .focusLost)
        let repeats = poster.postedEvents.filter {
            if case .keyDown(_, _, true) = $0 { return true } else { return false }
        }
        XCTAssertEqual(repeats.count, 1, "no key repeat may follow the focus loss")
        XCTAssertEqual(Array(poster.postedEvents.suffix(2)), [
            .keyUp(try key("w"), flags: .maskCommand),
            .modifierUp(try key("command"), flags: []),
        ])
    }

    func testUnfocusedTargetPressesNothing() throws {
        let plan = HeldKeysPlanner.plan(for: try request(["w"]), dragPath: nil)
        let poster = RecordingHeldInputPoster()
        XCTAssertEqual(play(plan, poster, targetFocused: { false }), .focusLost)
        XCTAssertTrue(poster.postedEvents.isEmpty)
    }

    func testInterruptionStopsFramesAndReleasesBeforeShutdownProceeds() throws {
        let drag = HeldKeysDrag(fromX: 0, fromY: 0, toX: 1, toY: 1, button: .right)
        let plan = HeldKeysPlanner.plan(for: try request(["w"], durationMs: 10_000, drag: drag),
                                        dragPath: (from, to))
        let poster = RecordingHeldInputPoster()
        let interruption = PlaybackInterruption()
        let finished = expectation(description: "playback returned")
        var outcome: HeldInputOutcome?
        // Real pauses, so the hold is still running when the interruption lands.
        let pacedPoster = PacedHeldInputPoster(recording: poster)
        DispatchQueue.global().async {
            outcome = HeldInputPlayback.play(plan, targetPID: nil, poster: pacedPoster,
                                             targetFocused: { true }, interruption: interruption)
            finished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(interruption.interruptAndWait(timeout: 2),
                      "shutdown must wait until the playback released")
        XCTAssertEqual(Array(poster.postedEvents.suffix(2)).map { event -> Bool in
            if case .buttonUp = event { return true }
            if case .keyUp = event { return true }
            return false
        }, [true, true], "the release ran before interruptAndWait returned")
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertFalse(interruption.begin(), "no playback may start once shutdown began")
    }

    // MARK: - InputSimulation.holdKeys

    private func makeInput(touchSession: TouchSession,
                           poster: RecordingHeldInputPoster) -> InputSimulation {
        let bridge = StubBridge()
        // Not running: a missing refusal stops at the state check instead of
        // activating a window on the Mac running the tests.
        bridge.state = .notRunning
        return InputSimulation(bridge: bridge, layoutSubstitution: [:],
                               touchSession: touchSession, heldInputPoster: poster)
    }

    func testHoldKeysRefusesWhileATouchIsHeld() throws {
        let session = TouchSession(poster: RecordingTouchPoster())
        defer { _ = session.cancel() }
        _ = session.begin(at: CGPoint(x: 10, y: 20),
                          window: WindowInfo(windowID: 1, position: .zero,
                                             size: CGSize(width: 410, height: 898), pid: 1),
                          targetPID: nil, restorePoint: nil)
        let poster = RecordingHeldInputPoster()
        let input = makeInput(touchSession: session, poster: poster)

        let error = input.holdKeys(try request(["w"]))
        XCTAssertTrue(error?.contains("hold_keys") ?? false, error ?? "nil")
        XCTAssertTrue(error?.contains("touch(action:\"cancel\")") ?? false, error ?? "nil")
        XCTAssertTrue(poster.calls.isEmpty)
        XCTAssertTrue(session.isHeld)
    }

    func testHoldKeysReportsTargetStateWithAndWithoutDrag() throws {
        let poster = RecordingHeldInputPoster()
        let input = makeInput(touchSession: TouchSession(poster: RecordingTouchPoster()), poster: poster)
        let expected = "Target 'iphone' is not running. Launch iPhone Mirroring first."
        XCTAssertEqual(input.holdKeys(try request(["w"])), expected)
        let drag = HeldKeysDrag(fromX: 10, fromY: 10, toX: 20, toY: 20, button: .right)
        XCTAssertEqual(input.holdKeys(try request(["w"], drag: drag)), expected)
        XCTAssertTrue(poster.calls.isEmpty)
    }

    private func makeConnectedInput(poster: RecordingHeldInputPoster) -> (InputSimulation, StubBridge) {
        let bridge = StubBridge()
        // Not running as a process: focusing only calls the stub's activate(),
        // so nothing on the Mac running the tests is brought forward.
        bridge.processRunning = false
        bridge.windowInfo = WindowInfo(windowID: 1, position: CGPoint(x: 100, y: 200),
                                       size: CGSize(width: 410, height: 898), pid: 1)
        let input = InputSimulation(bridge: bridge, layoutSubstitution: [:],
                                    touchSession: TouchSession(poster: RecordingTouchPoster()),
                                    heldInputPoster: poster)
        return (input, bridge)
    }

    func testHoldKeysDragRunsFromAndToTheWindowOffsetPoints() throws {
        let poster = RecordingHeldInputPoster()
        let (input, _) = makeConnectedInput(poster: poster)
        let drag = HeldKeysDrag(fromX: 10, fromY: 20, toX: 300, toY: 40, button: .right)
        XCTAssertNil(input.holdKeys(try request(["w"], durationMs: 200, drag: drag)))
        XCTAssertTrue(poster.postedEvents.contains(.buttonDown(.right, at: CGPoint(x: 110, y: 220))))
        let lastDrag = poster.postedEvents.last {
            if case .buttonDragged = $0 { return true } else { return false }
        }
        XCTAssertEqual(lastDrag, .buttonDragged(.right, to: CGPoint(x: 400, y: 240)))
        XCTAssertTrue(poster.postedEvents.contains(.buttonUp(.right, at: CGPoint(x: 400, y: 240))))
    }

    func testHoldKeysRefusesWhenTheTargetIsNotFrontmost() throws {
        let poster = RecordingHeldInputPoster()
        let (input, bridge) = makeConnectedInput(poster: poster)
        bridge.frontmost = false
        let error = input.holdKeys(try request(["command", "w"]))
        XCTAssertTrue(error?.contains("not the frontmost app") ?? false, error ?? "nil")
        XCTAssertTrue(poster.calls.isEmpty)
    }

    // MARK: - Live CGEvent construction

    func testLiveEventsCarryButtonTypeKeycodeAndAutoRepeat() throws {
        let rightDown = try XCTUnwrap(CGEventHeldInputPoster.makeEvent(.buttonDown(.right, at: from)))
        XCTAssertEqual(rightDown.type, .rightMouseDown)
        XCTAssertEqual(rightDown.getIntegerValueField(.mouseEventButtonNumber),
                       Int64(CGMouseButton.right.rawValue))
        XCTAssertEqual(rightDown.location, from)
        XCTAssertEqual(CGEventHeldInputPoster.makeEvent(.buttonDragged(.right, to: to))?.type,
                       .rightMouseDragged)
        XCTAssertEqual(CGEventHeldInputPoster.makeEvent(.buttonUp(.left, at: to))?.type, .leftMouseUp)

        let w = try key("w")
        let held = try XCTUnwrap(CGEventHeldInputPoster.makeEvent(.keyDown(w, flags: [], isRepeat: true)))
        XCTAssertEqual(held.type, .keyDown)
        XCTAssertEqual(held.getIntegerValueField(.keyboardEventKeycode), 13)
        XCTAssertEqual(held.getIntegerValueField(.keyboardEventAutorepeat), 1)
        let first = try XCTUnwrap(CGEventHeldInputPoster.makeEvent(.keyDown(w, flags: [], isRepeat: false)))
        XCTAssertEqual(first.getIntegerValueField(.keyboardEventAutorepeat), 0)

        let shift = try XCTUnwrap(CGEventHeldInputPoster.makeEvent(
            .modifierDown(try key("shift"), flags: .maskShift)))
        XCTAssertEqual(shift.type, .flagsChanged)
        XCTAssertTrue(shift.flags.contains(.maskShift))
    }
}

/// Forwards to a recording poster but really sleeps on `pause`, so a hold
/// lasts long enough for another thread to interrupt it mid-way. Signals
/// `started` (when given) once the first event went out.
final class PacedHeldInputPoster: HeldInputPosting, @unchecked Sendable {
    private let recording: RecordingHeldInputPoster
    private let started: DispatchSemaphore?
    private let lock = NSLock()
    private var signalled = false

    init(recording: RecordingHeldInputPoster, started: DispatchSemaphore? = nil) {
        self.recording = recording
        self.started = started
    }

    func engagePointer(targetPID: pid_t?) -> Bool { recording.engagePointer(targetPID: targetPID) }
    func disengagePointer(_ engaged: Bool) { recording.disengagePointer(engaged) }
    func post(_ event: HeldInputEvent, targetPID: pid_t?) -> Bool {
        let posted = recording.post(event, targetPID: targetPID)
        let first = lock.withLock { () -> Bool in
            defer { signalled = true }
            return !signalled
        }
        if first { started?.signal() }
        return posted
    }
    func pause(microseconds: UInt32) {
        recording.pause(microseconds: microseconds)
        usleep(microseconds)
    }
}
