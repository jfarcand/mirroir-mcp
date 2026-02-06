// ABOUTME: Captures screenshots of the iPhone Mirroring window using screencapture CLI.
// ABOUTME: Returns base64-encoded PNG data suitable for MCP image responses.

import CoreGraphics
import Foundation

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
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        // Read the captured file
        let fileURL = URL(fileURLWithPath: tempPath)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        return data.base64EncodedString()
    }
}
