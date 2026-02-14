// ABOUTME: Shared Process utility extensions used across the MCP server.
// ABOUTME: Provides a timeout-aware wait that prevents indefinite hangs from screencapture.

import Foundation

extension Process {
    /// Wait for the process to exit within the given timeout.
    /// Returns true if the process exited, false if the timeout was reached.
    /// Uses a polling loop with EnvConfig.processPollUs between checks.
    public func waitWithTimeout(seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while isRunning && Date() < deadline {
            usleep(EnvConfig.processPollUs)
        }
        return !isRunning
    }
}
