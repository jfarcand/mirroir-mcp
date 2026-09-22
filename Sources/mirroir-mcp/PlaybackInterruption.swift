// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Process-wide registry of input playbacks that hold keys, buttons or an open gesture.
// ABOUTME: Lets the exit path stop them between frames and wait until each ran its own release.

import Foundation

/// Tracks the playbacks that press something and keep it down for a while
/// (hold_keys, pinch/rotate, a one-shot drag, a long press).
///
/// A termination signal arrives on another thread while such a playback runs
/// on the main thread. Exiting right away would leave keys and buttons down in
/// the window server and an iOS gesture open. Instead the exit path calls
/// `interruptAndWait(timeout:)`: every running playback sees `isInterrupted`
/// at its next frame, skips its remaining frames, runs its normal release, and
/// leaves; the exit path waits for that, bounded by the timeout. Once
/// interrupted, no new playback may start.
///
/// Lifecycle per playback: `begin()` (false once interrupted) → frames that
/// check `isInterrupted` → release → `end()`. State is guarded by `condition`.
final class PlaybackInterruption: @unchecked Sendable {

    /// The registry every live playback uses: the Mac has one keyboard state
    /// and one pointer, so there is one shutdown to coordinate.
    static let shared = PlaybackInterruption()

    /// Longest slice `sleep(microseconds:)` waits before checking
    /// `isInterrupted` again, so a long hold notices a shutdown promptly.
    static let sleepSliceUs: UInt32 = 20_000

    private let condition = NSCondition()
    private var running = 0
    private var interrupted = false

    /// Register a playback about to press something. Returns false once the
    /// process is shutting down; the caller must then press nothing.
    func begin() -> Bool {
        condition.withLock {
            guard !interrupted else { return false }
            running += 1
            return true
        }
    }

    /// Unregister a playback after its release ran.
    func end() {
        condition.withLock {
            running = max(0, running - 1)
            condition.broadcast()
        }
    }

    /// Whether shutdown asked every playback to stop and release.
    var isInterrupted: Bool {
        condition.withLock { interrupted }
    }

    /// Ask every running playback to stop and release, then wait until all
    /// of them unregistered or `timeout` elapsed. Returns whether none is
    /// still running.
    @discardableResult
    func interruptAndWait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        return condition.withLock {
            interrupted = true
            while running > 0 {
                guard condition.wait(until: deadline) else { return running == 0 }
            }
            return true
        }
    }

    /// Sleep for `microseconds` in slices, returning early once interrupted.
    /// Returns whether the full time elapsed without an interruption.
    @discardableResult
    func sleep(microseconds: UInt32) -> Bool {
        var remaining = microseconds
        while remaining > 0 {
            if isInterrupted { return false }
            let slice = min(remaining, Self.sleepSliceUs)
            usleep(slice)
            remaining -= slice
        }
        return !isInterrupted
    }
}
