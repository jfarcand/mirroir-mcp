// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Quits FakeMirroring when the integration test bundle finishes, if the tests were the ones to start it.
// ABOUTME: An instance already running when the bundle first needs it (CI's setup action, a developer's) is left running.

import AppKit
import XCTest

/// Test-bundle observer that terminates FakeMirroring when the bundle
/// finishes. Tests share one FakeMirroring across the run (relaunching per test
/// would cost seconds each), so the end of the bundle is the one point where it
/// is safe to quit it. Ownership is decided once, at the bundle's first need:
/// when FakeMirroring was not running then, the tests started it and quit it;
/// when it was, whoever started it owns it — CI steps after the tests keep
/// driving it — even though a test may restart it mid-run.
final class FakeMirroringTeardown: NSObject, XCTestObservation {

    /// Seconds to wait for a graceful `terminate()` before `forceTerminate()`.
    static let gracefulQuitTimeoutSeconds: TimeInterval = 3

    nonisolated(unsafe) private static var registered = false
    private static let lock = NSLock()

    /// Decide ownership on the bundle's first need of FakeMirroring, and
    /// register the observer only when the tests are about to start it.
    static func claimIfNotRunning(isRunning: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        registered = true
        guard !isRunning else { return }
        let observer = FakeMirroringTeardown()
        if Thread.isMainThread {
            MainActor.assumeIsolated { XCTestObservationCenter.shared.addTestObserver(observer) }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { XCTestObservationCenter.shared.addTestObserver(observer) }
            }
        }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        Self.quitAll()
    }

    /// Terminate every running FakeMirroring, forcing any that ignore the
    /// graceful quit within `gracefulQuitTimeoutSeconds`.
    static func quitAll() {
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: IntegrationTestHelper.fakeBundleID)
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(gracefulQuitTimeoutSeconds)
        while Date() < deadline, apps.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        apps.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }
}
