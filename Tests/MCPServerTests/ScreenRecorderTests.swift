// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for ScreenRecorder's lifecycle with a real child process in place of screencapture.
// ABOUTME: Covers a recording that ends on its own, a normal stop, and the display-awake hold around both.

import Foundation
import os
import XCTest
@testable import mirroir_mcp

/// Counts the display-awake assertions a recording takes, without IOKit.
private final class RecorderAsserter: DisplayAwakeAsserting, @unchecked Sendable {
    let taken = OSAllocatedUnfairLock(initialState: 0)
    let released = OSAllocatedUnfairLock(initialState: 0)
    func assertAwake(reason: String) -> UInt32? { taken.withLock { $0 += 1; return UInt32($0) } }
    func release(_ assertion: UInt32) { released.withLock { $0 += 1 } }
}

final class ScreenRecorderTests: XCTestCase {

    private var directory = ""
    private var video: String { directory + "/video.mov" }
    private let asserter = RecorderAsserter()

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "recorder-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
    }

    /// A stand-in for screencapture: writes the file, then runs `script`.
    private func recorder(_ script: String) -> ScreenRecorder {
        ScreenRecorder(
            bridge: StubBridge(), displayAwake: DisplayAwake(asserter: asserter, enabled: { true }),
            command: { _, path in
                (URL(fileURLWithPath: "/bin/sh"), ["-c", "echo frames > \"$0\"; " + script, path])
            })
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { usleep(50_000) }
    }

    /// The process outlives the start check, then exits on its own, the way
    /// screencapture did around display sleep.
    func testARecordingThatEndedOnItsOwnStillReturnsItsFile() {
        // Outlives the start check (earlyFailureDetectUs, 0.5 s) with room to spare on CI.
        let recorder = recorder("sleep 2")
        XCTAssertNil(recorder.startRecording(outputPath: video))
        waitUntil { !recorder.isRecording }
        waitUntil { asserter.released.withLock { $0 } == 1 }
        XCTAssertEqual(asserter.released.withLock { $0 }, 1, "the display is let sleep once it ended")

        let refused = recorder.startRecording(outputPath: directory + "/next.mov")
        XCTAssertTrue(refused?.contains("ended on its own") ?? false, refused ?? "")
        XCTAssertTrue(refused?.contains(video) ?? false, refused ?? "")

        let stop = recorder.stopRecording()
        XCTAssertEqual(stop.filePath, video)
        XCTAssertNil(stop.error)
        XCTAssertTrue(stop.endedEarly?.contains("exit status 0") ?? false, stop.endedEarly ?? "")
        XCTAssertEqual(recorder.stopRecording().error, "No recording in progress", "collected once")
    }

    func testAStoppedRecordingReturnsItsFileAndReleasesTheDisplay() {
        let recorder = recorder("trap 'exit 2' INT; while :; do sleep 0.1; done")
        XCTAssertNil(recorder.startRecording(outputPath: video))
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(asserter.taken.withLock { $0 }, 1)

        let stop = recorder.stopRecording()
        XCTAssertEqual(stop.filePath, video)
        XCTAssertNil(stop.endedEarly)
        waitUntil { asserter.released.withLock { $0 } == 1 }
        XCTAssertEqual(asserter.released.withLock { $0 }, 1)
        XCTAssertNil(recorder.startRecording(outputPath: directory + "/again.mov"), "a collected one can restart")
        _ = recorder.stopRecording()
    }

    func testAProcessThatDiesAtOnceIsAFailedStart() {
        let recorder = recorder("exit 1")
        let error = recorder.startRecording(outputPath: video)
        XCTAssertTrue(error?.contains("failed to start (exit code 1)") ?? false, error ?? "")
        XCTAssertEqual(recorder.stopRecording().error, "No recording in progress")
        waitUntil { asserter.released.withLock { $0 } == 1 }
        XCTAssertEqual(asserter.released.withLock { $0 }, 1)
    }
}
