// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Shared setup logic for integration tests that target the FakeMirroring app.
// ABOUTME: Auto-detects FakeMirroring by process lookup and provides the bundle ID for bridge init.

import AppKit
@testable import mirroir_mcp

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
        maxAttempts: Int = 5
    ) -> Bool {
        for attempt in 1...maxAttempts {
            bridge.activate()
            usleep(300_000) // 300ms for activation to take effect
            if let info = bridge.getWindowInfo(), info.windowID != 0 {
                return true
            }
            if attempt < maxAttempts {
                usleep(500_000) // 500ms between retries
            }
        }
        return false
    }
}
