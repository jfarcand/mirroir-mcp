// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Records video of the iPhone Mirroring window using macOS screencapture CLI.
// ABOUTME: Manages start/stop, keeps the display awake meanwhile, and reports a recording that ended on its own.

import Foundation
import HelperLib
import os

/// Records the iPhone Mirroring window as a video file.
/// Uses the macOS `screencapture -v -l <windowID>` command which records
/// a specific window until stopped via SIGINT.
///
/// screencapture can end on its own (measured once around display sleep).
/// The recorder then keeps the file's path, so `stopRecording` still returns
/// the partial video and says the recording ended early, and a new
/// `startRecording` refuses until that video was collected.
///
/// Requires Screen Recording permission in System Preferences > Privacy & Security.
final class ScreenRecorder: Sendable {
    private let bridge: any WindowBridging
    private let displayAwake: DisplayAwake
    private let command: @Sendable (_ windowID: UInt32, _ path: String) -> (URL, [String])

    /// The screencapture command that records `windowID` into `path`.
    static func screencapture(windowID: UInt32, path: String) -> (URL, [String]) {
        (URL(fileURLWithPath: "/usr/sbin/screencapture"), ["-v", "-l", String(windowID), "-x", "-o", path])
    }

    /// screencapture's exit status when SIGINT stops it, as `stopRecording` does.
    static let interruptedStatus: Int32 = 2

    /// Mutable recording state protected by an unfair lock.
    /// Uses @unchecked Sendable because Process is not Sendable but access
    /// is serialized through OSAllocatedUnfairLock.
    private struct RecordingState: @unchecked Sendable {
        var process: Process?
        var path: String?
        /// Set by `stopRecording` before it interrupts, so the end it causes
        /// is not taken for an early one.
        var stopping = false
        /// When the process ended without being asked to.
        var endedEarlyAt: Date?
    }
    private let state = OSAllocatedUnfairLock(initialState: RecordingState())

    /// - Parameters:
    ///   - displayAwake: kept entered while a recording runs.
    ///   - command: the program and arguments that record a window into a file.
    init(bridge: any WindowBridging, displayAwake: DisplayAwake = .shared,
         command: @escaping @Sendable (UInt32, String) -> (URL, [String]) = ScreenRecorder.screencapture) {
        self.bridge = bridge
        self.displayAwake = displayAwake
        self.command = command
    }

    /// Whether a recording is currently in progress.
    var isRecording: Bool {
        return state.withLock { $0.process?.isRunning ?? false }
    }

    /// Start recording the mirroring window.
    /// Returns nil on success, or an error message on failure.
    func startRecording(outputPath: String? = nil) -> String? {
        let (running, uncollected) = state.withLock { ($0.process?.isRunning ?? false, $0.path) }
        if running {
            return "Recording already in progress. Stop the current recording first."
        }
        if let uncollected {
            return "The previous recording ended on its own and was not collected; its video is at "
                + "\(uncollected). Call stop_recording to collect it, then start again."
        }

        guard let info = bridge.getWindowInfo(), info.windowID != 0 else {
            return "Target window not found"
        }

        let path = outputPath ?? defaultRecordingPath()
        let (executable, arguments) = command(info.windowID, path)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        // Suppress stdout/stderr from screencapture
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        displayAwake.enter(reason: "mirroir-mcp start_recording")
        process.terminationHandler = { [state, displayAwake] ended in
            state.withLock { current in
                guard current.process === ended, !current.stopping else { return }
                current.endedEarlyAt = Date()
            }
            DebugLog.persist("recording", "screencapture exited with status \(ended.terminationStatus)")
            displayAwake.leave()
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            displayAwake.leave()
            return "Failed to start recording: \(error.localizedDescription)"
        }

        state.withLock {
            $0 = RecordingState(process: process, path: path)
        }

        // Verify the process actually started (Screen Recording permission may block it)
        usleep(EnvConfig.earlyFailureDetectUs)
        guard process.isRunning else {
            state.withLock { $0 = RecordingState() }
            let status = process.terminationStatus
            return "Recording failed to start (exit code \(status)). "
                + "Check Screen Recording permission in System Preferences > Privacy & Security."
        }
        return nil
    }

    /// Stop the current recording and return the recorded file. A recording
    /// that already ended on its own still returns its file, with `endedEarly`
    /// saying so.
    func stopRecording() -> RecordingStop {
        let (process, path) = state.withLock { s -> (Process?, String?) in
            if s.process?.isRunning == true { s.stopping = true }
            return (s.process, s.path)
        }

        guard let process, let path else {
            return RecordingStop(filePath: nil, error: "No recording in progress")
        }

        var endedEarly: String?
        if process.isRunning {
            // Send SIGINT to gracefully stop screencapture (same as Ctrl+C)
            process.interrupt()
            process.waitUntilExit()
        } else {
            process.waitUntilExit()
            let at = state.withLock { $0.endedEarlyAt }
            let when = at.map { " at " + ISO8601DateFormatter().string(from: $0) } ?? ""
            endedEarly = "the recording had already ended on its own\(when) "
                + "(screencapture exit status \(process.terminationStatus)), before stop_recording; "
                + "display sleep or a locked Mac can end it"
        }

        state.withLock { $0 = RecordingState() }

        let status = process.terminationStatus
        let exists = FileManager.default.fileExists(atPath: path)
        if endedEarly == nil, status != 0, status != Self.interruptedStatus {
            return RecordingStop(filePath: nil, error: "Recording stopped with error (exit code \(status))")
        }
        guard exists else {
            let error = endedEarly.map { "No video was saved: \($0)." }
                ?? "Recording file not found at expected path"
            return RecordingStop(filePath: nil, error: error)
        }
        return RecordingStop(filePath: path, error: nil, endedEarly: endedEarly)
    }

    /// Generate a default recording path in the temp directory.
    private func defaultRecordingPath() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return NSTemporaryDirectory() + "mirroir-recording-\(timestamp).mov"
    }
}
