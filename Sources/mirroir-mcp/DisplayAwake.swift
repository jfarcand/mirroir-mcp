// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Keeps the Mac's display awake while a run acts on the mirror: tool calls, test/compile/record runs, recordings.
// ABOUTME: One reference-counted IOKit assertion (PreventUserIdleDisplaySleep), the same one `caffeinate -d` holds.

import Foundation
import HelperLib
import IOKit.pwr_mgt

/// Holds one display-awake assertion while any run is active.
///
/// Synthetic input does not reset the Mac's idle timer, so a long run that
/// sends nothing but CGEvents is overtaken by the screen saver, whose
/// loginwindow then covers the mirror. Every run enters the hold and leaves it
/// when done; the assertion is taken by the first and released by the last.
/// Between two runs, or two tool calls, nothing is held.
final class DisplayAwake: @unchecked Sendable {

    /// The hold every run in this process shares.
    static let shared = DisplayAwake(asserter: IOPMDisplayAwake(), enabled: { EnvConfig.keepDisplayAwake })

    private let asserter: any DisplayAwakeAsserting
    private let enabled: @Sendable () -> Bool
    private let lock = NSLock()
    private var holders = 0
    private var assertion: UInt32?

    init(asserter: any DisplayAwakeAsserting, enabled: @escaping @Sendable () -> Bool) {
        self.asserter = asserter
        self.enabled = enabled
    }

    /// Whether the display is being kept awake right now.
    var isHeld: Bool { lock.withLock { assertion != nil } }

    /// Start a run; the first one takes the assertion.
    func enter(reason: String) {
        guard enabled() else { return }
        lock.withLock {
            holders += 1
            if assertion == nil {
                assertion = asserter.assertAwake(reason: reason)
                DebugLog.log("display-awake", assertion == nil
                    ? "macOS refused the display-awake assertion for \(reason)" : "held for \(reason)")
            }
        }
    }

    /// End a run `enter` started; the last one releases the assertion.
    func leave() {
        lock.withLock {
            guard holders > 0 else { return }
            holders -= 1
            if holders == 0, let held = assertion {
                asserter.release(held)
                assertion = nil
                DebugLog.log("display-awake", "released")
            }
        }
    }

    /// Run `body` with the display kept awake.
    func during<T>(_ reason: String, _ body: () throws -> T) rethrows -> T {
        enter(reason: reason)
        defer { leave() }
        return try body()
    }
}

/// The IOKit power assertion `caffeinate -d` holds.
struct IOPMDisplayAwake: DisplayAwakeAsserting {

    func assertAwake(reason: String) -> UInt32? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    func release(_ assertion: UInt32) {
        IOPMAssertionRelease(assertion)
    }
}
