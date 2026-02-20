// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Records video of the iPhone Mirroring window using macOS screencapture CLI.
// ABOUTME: Manages start/stop lifecycle and returns the path to the recorded .mov file.

import Foundation
import HelperLib
import os

/// Records the iPhone Mirroring window as a video file.
/// Uses the macOS `screencapture -v -l <windowID>` command which records
/// a specific window until stopped via SIGINT.
///
/// Requires Screen Recording permission in System Preferences > Privacy & Security.
final class ScreenRecorder: Sendable {
    private let bridge: any WindowBridging

    /// Mutable recording state protected by an unfair lock.
    /// Uses @unchecked Sendable because Process is not Sendable but access
    /// is serialized through OSAllocatedUnfairLock.
    private struct RecordingState: @unchecked Sendable {
        var process: Process?
        var path: String?
    }
    private let state = OSAllocatedUnfairLock(initialState: RecordingState())

    init(bridge: any WindowBridging) {
        self.bridge = bridge
    }

    /// Whether a recording is currently in progress.
    var isRecording: Bool {
        return state.withLock { $0.process?.isRunning ?? false }
    }

    /// Start recording the mirroring window.
    /// Returns nil on success, or an error message on failure.
    func startRecording(outputPath: String? = nil) -> String? {
        guard !isRecording else {
            return "Recording already in progress. Stop the current recording first."
        }

        guard let info = bridge.getWindowInfo(), info.windowID != 0 else {
            return "iPhone Mirroring window not found"
        }

        let path = outputPath ?? defaultRecordingPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-v", "-l", String(info.windowID), "-x", "-o", path]

        // Suppress stdout/stderr from screencapture
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return "Failed to start recording: \(error.localizedDescription)"
        }

        // Verify the process actually started (Screen Recording permission may block it)
        usleep(EnvConfig.earlyFailureDetectUs)
        guard process.isRunning else {
            let status = process.terminationStatus
            return "Recording failed to start (exit code \(status)). "
                + "Check Screen Recording permission in System Preferences > Privacy & Security."
        }

        state.withLock {
            $0.process = process
            $0.path = path
        }
        return nil
    }

    /// Stop the current recording and return the path to the recorded file.
    /// Returns a tuple of (filePath, errorMessage). On success, filePath is set.
    /// On failure, errorMessage is set.
    func stopRecording() -> (filePath: String?, error: String?) {
        let (process, path) = state.withLock { s -> (Process?, String?) in
            let p = s.process
            let pt = s.path
            return (p, pt)
        }

        guard let process = process, process.isRunning else {
            return (nil, "No recording in progress")
        }

        // Send SIGINT to gracefully stop screencapture (same as Ctrl+C)
        process.interrupt()
        process.waitUntilExit()

        state.withLock {
            $0.process = nil
            $0.path = nil
        }

        guard process.terminationStatus == 0 || process.terminationStatus == 2 else {
            // Exit code 2 is normal for SIGINT termination
            return (nil, "Recording stopped with error (exit code \(process.terminationStatus))")
        }

        // Verify the file was created
        guard let filePath = path,
              FileManager.default.fileExists(atPath: filePath) else {
            return (nil, "Recording file not found at expected path")
        }

        return (filePath, nil)
    }

    /// Generate a default recording path in the temp directory.
    private func defaultRecordingPath() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return NSTemporaryDirectory() + "iphone-mirroir-recording-\(timestamp).mov"
    }
}
