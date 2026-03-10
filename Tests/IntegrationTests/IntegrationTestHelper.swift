// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Shared setup logic for integration tests that target the FakeMirroring app.
// ABOUTME: Auto-launches FakeMirroring if not running and hard-fails if launch fails.

import AppKit
@testable import mirroir_mcp

/// Errors thrown by integration tests when the FakeMirroring environment is not ready.
/// These produce hard test failures (not silent skips) because FakeMirroring must
/// always be running when integration tests execute.
enum IntegrationTestError: Error, CustomStringConvertible {
    case fakeMirroringNotFound
    case fakeMirroringLaunchFailed(String)
    case windowNotCapturable
    case describeReturnedNil
    case windowInfoUnavailable
    case elementNotFound(String)
    case notEnoughElements(Int)

    var description: String {
        switch self {
        case .fakeMirroringNotFound:
            return "FakeMirroring.app not found. Build with: swift build -c release"
        case .fakeMirroringLaunchFailed(let reason):
            return "FakeMirroring failed to launch: \(reason)"
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

    /// Relative path from the package root to the release-built FakeMirroring app.
    static let appRelativePath = ".build/release/FakeMirroring.app"

    /// Check if FakeMirroring is running by looking up its bundle ID in the process list.
    static var isFakeMirroringRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: fakeBundleID
        ).isEmpty
    }

    /// Ensure FakeMirroring is running. Auto-launches from the release build if not.
    /// Throws a hard error if the app cannot be found or launched — integration tests
    /// must never silently skip.
    static func ensureFakeMirroringRunning() throws {
        if isFakeMirroringRunning { return }

        // Resolve app path relative to the package root (parent of .build/)
        let appURL = resolveAppURL()
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw IntegrationTestError.fakeMirroringNotFound
        }

        // Launch the app
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var launchError: Error?

        NSWorkspace.shared.openApplication(
            at: appURL, configuration: config
        ) { _, error in
            launchError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let error = launchError {
            throw IntegrationTestError.fakeMirroringLaunchFailed(error.localizedDescription)
        }

        // Wait for the process to appear (up to 5 seconds)
        for _ in 0..<10 {
            usleep(500_000)
            if isFakeMirroringRunning { return }
        }

        throw IntegrationTestError.fakeMirroringLaunchFailed(
            "Process did not appear within 5 seconds after launch")
    }

    /// Activate FakeMirroring and wait until its window is capturable (non-zero windowID).
    /// Under heavy screencapture load, CGWindowListCopyWindowInfo can transiently fail
    /// to list the window. This helper retries until the window is back.
    /// Returns true if successful, false if recovery failed after all attempts.
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

    /// Resolve the FakeMirroring.app URL by walking up from the test bundle
    /// to find the package root (where Package.swift lives).
    private static func resolveAppURL() -> URL {
        // The test binary runs from .build/debug or .build/release.
        // Walk up from the executable to find the package root.
        var dir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // IntegrationTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        // Safety: if #file resolution changed, try the current working directory
        if !FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Package.swift").path
        ) {
            dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        return dir.appendingPathComponent(appRelativePath)
    }
}
