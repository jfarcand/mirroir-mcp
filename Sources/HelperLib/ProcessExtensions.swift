// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Shared Process utility extensions used across the MCP server.
// ABOUTME: Provides a timeout-aware wait that prevents indefinite hangs from screencapture.

import Foundation

/// Outcome of a timeout-bounded wait on a process.
public enum WaitResult: Sendable, Equatable {
    /// Process exited (normally or via signal) with the given termination status.
    case exited(status: Int32)
    /// The timeout elapsed and the process is still running.
    case timedOut

    /// Convenience: true when the process exited before the deadline.
    public var didExit: Bool {
        if case .exited = self { return true }
        return false
    }
}

extension Process {
    /// Wait for the process to exit within the given timeout.
    /// Returns `.exited(status:)` if the process finished, `.timedOut` otherwise.
    /// Uses a polling loop with EnvConfig.processPollUs between checks.
    public func waitWithTimeout(seconds: Int) -> WaitResult {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while isRunning && Date() < deadline {
            usleep(EnvConfig.processPollUs)
        }
        if isRunning {
            return .timedOut
        }
        return .exited(status: terminationStatus)
    }
}
