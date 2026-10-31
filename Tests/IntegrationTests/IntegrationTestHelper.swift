// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Shared setup logic for integration tests that target the FakeMirroring app.
// ABOUTME: Auto-launches FakeMirroring if not running, hard-fails if launch fails, and quits it at bundle end if it started it.

import AppKit
@testable import mirroir_mcp

/// Errors thrown by integration tests when the FakeMirroring environment is not ready.
/// These produce hard test failures (not silent skips) because FakeMirroring must
/// always be running when integration tests execute.
enum IntegrationTestError: Error, CustomStringConvertible {
    case fakeMirroringNotFound
    case fakeMirroringLaunchFailed(String)
    case fakeMirroringTerminateFailed
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
        case .fakeMirroringTerminateFailed:
            return "FakeMirroring did not exit after terminate() and forceTerminate()"
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
        FakeMirroringTeardown.claimIfNotRunning(isRunning: isFakeMirroringRunning)
        if isFakeMirroringRunning { return }

        // Resolve app path relative to the package root (parent of .build/)
        let appURL = resolveAppURL()
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw IntegrationTestError.fakeMirroringNotFound
        }

        // Launch the app — float the window so CGEvent taps and screencapture
        // always hit FakeMirroring even if another app momentarily grabs focus
        // (terminal, IDE, etc.) during the test run.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.environment = ["FAKEMIRRORING_FLOATING": "1"]

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

    /// Reset FakeMirroring to a fresh cold-launch of the named scenario pack.
    /// Routes through the Scenario menu, which the AppDelegate implements as
    /// force-quit + launch — clears any persistent obstacle/screen state from
    /// prior test interactions. Returns true if the menu action succeeded.
    @discardableResult
    static func resetScenario(
        bridge: MirroringBridge,
        to scenarioName: String = "Settings"
    ) -> Bool {
        let ok = bridge.triggerMenuAction(menu: "Scenario", item: scenarioName)
        // Give the runloop a tick to render the freshly-launched scene before
        // the test starts capturing/describing.
        usleep(200_000)
        return ok
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
