// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Captures screenshots of the iPhone Mirroring window using screencapture CLI.
// ABOUTME: Returns base64-encoded PNG data suitable for MCP image responses.

import CoreGraphics
import Foundation
import HelperLib

/// Captures the iPhone Mirroring window content as a screenshot.
/// Uses the macOS `screencapture` command since CGWindowListCreateImage
/// is unavailable on macOS 15+ (replaced by ScreenCaptureKit).
final class ScreenCapture: @unchecked Sendable {
    private let bridge: MirroringBridge

    init(bridge: MirroringBridge) {
        self.bridge = bridge
    }

    /// Capture the mirroring window and return base64-encoded PNG.
    func captureBase64() -> String? {
        guard let info = bridge.getWindowInfo(), info.windowID != 0 else { return nil }

        // Use screencapture CLI with -l flag to capture a specific window by ID
        let tempPath = NSTemporaryDirectory() + "iphone-mirroir-mcp-\(ProcessInfo.processInfo.processIdentifier).png"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l", String(info.windowID), "-x", "-o", tempPath]

        do {
            try process.run()
        } catch {
            return nil
        }

        // Wait with timeout to prevent indefinite hangs
        let completed = waitForProcess(process, timeoutSeconds: 10)
        if !completed {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        // Read the captured file
        let fileURL = URL(fileURLWithPath: tempPath)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            DebugLog.log("ScreenCapture", "Failed to read screenshot: \(error)")
            return nil
        }

        return data.base64EncodedString()
    }

    /// Wait for a process to exit within the given timeout.
    /// Returns true if the process exited, false if the timeout was reached.
    private func waitForProcess(_ process: Process, timeoutSeconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline {
            usleep(EnvConfig.processPollUs)
        }
        return !process.isRunning
    }
}
