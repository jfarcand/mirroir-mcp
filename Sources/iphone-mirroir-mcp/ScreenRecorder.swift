// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Records video of the iPhone Mirroring window using macOS screencapture CLI.
// ABOUTME: Manages start/stop lifecycle and returns the path to the recorded .mov file.

import Foundation

/// Records the iPhone Mirroring window as a video file.
/// Uses the macOS `screencapture -v -l <windowID>` command which records
/// a specific window until stopped via SIGINT.
///
/// Requires Screen Recording permission in System Preferences > Privacy & Security.
final class ScreenRecorder: @unchecked Sendable {
    private let bridge: MirroringBridge
    private var recordingProcess: Process?
    private var recordingPath: String?

    init(bridge: MirroringBridge) {
        self.bridge = bridge
    }

    /// Whether a recording is currently in progress.
    var isRecording: Bool {
        return recordingProcess?.isRunning ?? false
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
        usleep(500_000) // 500ms to detect early failure
        guard process.isRunning else {
            let status = process.terminationStatus
            return "Recording failed to start (exit code \(status)). "
                + "Check Screen Recording permission in System Preferences > Privacy & Security."
        }

        recordingProcess = process
        recordingPath = path
        return nil
    }

    /// Stop the current recording and return the path to the recorded file.
    /// Returns a tuple of (filePath, errorMessage). On success, filePath is set.
    /// On failure, errorMessage is set.
    func stopRecording() -> (filePath: String?, error: String?) {
        guard let process = recordingProcess, process.isRunning else {
            return (nil, "No recording in progress")
        }

        let path = recordingPath

        // Send SIGINT to gracefully stop screencapture (same as Ctrl+C)
        process.interrupt()
        process.waitUntilExit()

        recordingProcess = nil
        recordingPath = nil

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
