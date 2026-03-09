// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Shared setup logic for integration tests that target the FakeMirroring app.
// ABOUTME: Auto-detects FakeMirroring by process lookup and provides the bundle ID for bridge init.

import AppKit
@testable import mirroir_mcp

/// Errors thrown by integration tests when the FakeMirroring environment is not ready.
/// These produce hard test failures (not silent skips) because FakeMirroring must
/// always be running when integration tests execute.
enum IntegrationTestError: Error, CustomStringConvertible {
    case fakeMirroringNotRunning
    case windowNotCapturable
    case describeReturnedNil
    case windowInfoUnavailable
    case elementNotFound(String)
    case notEnoughElements(Int)

    var description: String {
        switch self {
        case .fakeMirroringNotRunning:
            return "FakeMirroring must be running. Launch: open .build/release/FakeMirroring.app"
        case .windowNotCapturable:
            return "FakeMirroring window not capturable after retries"
        case .describeReturnedNil:
            return "describe() returned nil after retries"
        case .windowInfoUnavailable:
            return "Cannot get window info from bridge"
        case .elementNotFound(let name):
            return "'\(name)' not found by OCR on FakeMirroring screen"
        case .notEnoughElements(let count):
            return "Only \(count) elements on screen, need more for test"
        }
    }
}

/// Shared helpers for integration tests that need FakeMirroring.
enum IntegrationTestHelper {

    static let fakeBundleID = "com.jfarcand.FakeMirroring"

    /// Check if FakeMirroring is running by looking up its bundle ID in the process list.
    static var isFakeMirroringRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: fakeBundleID
        ).isEmpty
    }

    /// Activate FakeMirroring and wait until its window is capturable (non-zero windowID).
    /// Under heavy screencapture load, CGWindowListCopyWindowInfo can transiently fail
    /// to list the window. This helper retries until the window is back.
    /// Returns the bridge if successful, nil if recovery failed after all attempts.
    @discardableResult
    static func ensureWindowReady(
        bridge: MirroringBridge,
        maxAttempts: Int = 10
    ) -> Bool {
        for attempt in 1...maxAttempts {
            bridge.activate()
            usleep(500_000) // 500ms for activation to take effect
            if let info = bridge.getWindowInfo(), info.windowID != 0 {
                return true
            }
            if attempt < maxAttempts {
                usleep(1_000_000) // 1s between retries under test contention
            }
        }
        return false
    }
}
