// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Captures screenshots of the iPhone Mirroring window using screencapture CLI.
// ABOUTME: Returns base64-encoded PNG data suitable for MCP image responses.

import CoreGraphics
import Foundation
import HelperLib

/// Captures a target window as a screenshot using the macOS `screencapture` CLI.
/// Uses CGWindowListCreateImage is unavailable on macOS 15+ (replaced by
/// ScreenCaptureKit), so we shell out to `screencapture` instead.
///
/// Capture strategy:
/// 1. Try `screencapture -l <windowID>` (window-ID capture) — works for normal windows.
/// 2. If that fails (fullscreen / Split View windows), fall back to
///    `screencapture -R x,y,w,h` (region capture) using the window's known bounds.
final class ScreenCapture: Sendable {
    private let bridge: any WindowBridging

    init(bridge: any WindowBridging) {
        self.bridge = bridge
    }

    /// Capture the target window and return raw PNG data.
    func captureData() -> Data? {
        guard let info = bridge.getWindowInfo(), info.windowID != 0 else { return nil }

        // Activate the target so it's on the current Space — screencapture
        // cannot capture windows on other macOS Spaces.
        bridge.activate()
        usleep(EnvConfig.cursorSettleUs)

        let tempPath = NSTemporaryDirectory()
            + "mirroir-mcp-\(ProcessInfo.processInfo.processIdentifier).png"

        // Strategy 1: window-ID capture
        if let data = captureByWindowID(info.windowID, to: tempPath) {
            return data
        }

        // Strategy 2: region capture (handles fullscreen / Split View)
        DebugLog.log("ScreenCapture",
            "Window-ID capture failed for \(info.windowID), falling back to region capture")
        return captureByRegion(info, to: tempPath)
    }

    /// Capture the target window and return base64-encoded PNG.
    func captureBase64() -> String? {
        return captureData()?.base64EncodedString()
    }

    // MARK: - Capture strategies

    /// Capture a specific window by its CGWindowID using `screencapture -l`.
    private func captureByWindowID(_ windowID: CGWindowID, to path: String) -> Data? {
        return runScreencapture(
            arguments: ["-l", String(windowID), "-x", "-o", path],
            outputPath: path
        )
    }

    /// Capture a screen region matching the window bounds using `screencapture -R`.
    /// This works for fullscreen and Split View windows where -l fails.
    private func captureByRegion(_ info: WindowInfo, to path: String) -> Data? {
        let region = "\(Int(info.position.x)),\(Int(info.position.y)),"
            + "\(Int(info.size.width)),\(Int(info.size.height))"
        return runScreencapture(
            arguments: ["-R", region, "-x", "-o", path],
            outputPath: path
        )
    }

    /// Run screencapture with the given arguments and read the output file.
    private func runScreencapture(arguments: [String], outputPath: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments

        do {
            try process.run()
        } catch {
            return nil
        }

        guard case .exited(let status) = process.waitWithTimeout(seconds: 10) else {
            process.terminate()
            return nil
        }

        guard status == 0 else { return nil }

        let fileURL = URL(fileURLWithPath: outputPath)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            return try Data(contentsOf: fileURL)
        } catch {
            DebugLog.log("ScreenCapture", "Failed to read screenshot: \(error)")
            return nil
        }
    }
}
