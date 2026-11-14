// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests when a listen recording stops early: a silent start, silence after sound, or never (continuous sound).
// ABOUTME: Feeds ListenStopTracker buffer peaks the way ScreenCaptureKitAudio's sink does.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class ListenStopRuleTests: XCTestCase {

    private let rule = ListenStopRule(silencePeak: 0.01, silentStart: 4, trailingSilence: 3)

    /// Feed `peaks`, one buffer of `seconds` each, and return the first stop, if any.
    private func run(_ peaks: [Float], seconds: Double = 0.5) -> (end: RecordingEnd?, tracker: ListenStopTracker) {
        var tracker = ListenStopTracker(rule: rule)
        for peak in peaks {
            if let end = tracker.add(bufferPeak: peak, seconds: seconds) { return (end, tracker) }
        }
        return (nil, tracker)
    }

    func testSilenceFromTheStartStopsAfterTheSilentStart() {
        let result = run(Array(repeating: 0.001, count: 20))
        XCTAssertEqual(result.end, .silentStart)
        XCTAssertEqual(result.tracker.recorded, 4, "stopped at 4 s, not after the 10 s fed")
    }

    func testSoundThenSilenceStopsOnTrailingSilence() {
        let result = run(Array(repeating: 0.6, count: 10) + Array(repeating: 0.001, count: 20))
        XCTAssertEqual(result.end, .soundEnded)
        XCTAssertEqual(result.tracker.recorded, 8, "5 s of sound, then 3 s of silence")
        XCTAssertEqual(result.tracker.peak, 0.6)
    }

    func testAPauseShorterThanTheTrailingSilenceKeepsRecording() {
        let peaks: [Float] = [0.6, 0.6, 0.001, 0.001, 0.001, 0.001, 0.7, 0.7]
        XCTAssertNil(run(peaks).end, "2 s between two sentences is not the end")
    }

    /// A reel whose music never pauses is never silent, even as it loops:
    /// loudness alone cannot tell, so it records its full length.
    func testContinuousSoundNeverStops() {
        XCTAssertNil(run(Array(repeating: 0.3, count: 200)).end)
    }

    func testSoundStartingLateWithinTheSilentStartIsRecorded() {
        let peaks: [Float] = Array(repeating: 0.001, count: 6) + Array(repeating: 0.5, count: 10)
        let result = run(peaks)
        XCTAssertNil(result.end, "3 s of silence before the sound is under the 4 s silent start")
        XCTAssertEqual(result.tracker.recorded, 8)
    }

    func testTheSilencePeakIsTheBoundary() {
        XCTAssertEqual(run(Array(repeating: 0.0099, count: 8)).end, .silentStart)
        XCTAssertNil(run(Array(repeating: 0.01, count: 8)).end, "at the peak is sound")
    }

    func testTheRuleFromSettingsUsesTheDefaults() {
        XCTAssertEqual(ListenStopRule.fromSettings, ListenStopRule(
            silencePeak: Float(TimingConstants.listenSilencePeak),
            silentStart: TimingConstants.listenSilentStartSeconds,
            trailingSilence: TimingConstants.listenTrailingSilenceSeconds))
    }

    func testTheReplyRoundsTheLengthToATenth() {
        XCTAssertEqual(AudioListener.format(10), "10 s")
        XCTAssertEqual(AudioListener.format(9.98), "10 s")
        XCTAssertEqual(AudioListener.format(36.04), "36 s")
        XCTAssertEqual(AudioListener.format(4.12), "4.1 s")
    }
}
