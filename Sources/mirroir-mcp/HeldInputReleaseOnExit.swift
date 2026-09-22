// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Releases all held input on every server exit path: the touch contact and running hold playbacks.
// ABOUTME: Keys, buttons or a gesture left down after the server dies would break input for the whole Mac.

import Darwin
import Dispatch
import Foundation

/// Installs the exit-path releases of everything the server can hold down:
/// the persistent touch contact (`TouchSession.shared`) and the playbacks
/// registered with `PlaybackInterruption.shared` (hold_keys, pinch/rotate,
/// a one-shot drag, a long press).
///
/// Covers `exit()` from any thread (an `atexit` handler) and the termination
/// signals an MCP client or a terminal sends (SIGTERM, SIGINT, SIGHUP), which
/// otherwise kill the process without running any cleanup. Each signal is
/// handled on a dispatch queue: running playbacks are stopped and waited for
/// while they run their own release, the touch contact is lifted, then the
/// process exits with the conventional `128 + signal` status.
///
/// A crash (a trap or a fault) runs none of these handlers; the argument
/// parsing that feeds held input is total (`JSONValue.asInt` never traps) so
/// a hostile argument cannot crash the server while something is held.
enum HeldInputReleaseOnExit {

    /// Signals that end the server and must release held input first.
    static let terminationSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    /// Longest the exit path waits for running playbacks to release. A
    /// playback notices the interruption within one frame and releases in a
    /// few settle intervals, so this bound only matters if one is wedged.
    static let playbackReleaseTimeout: TimeInterval = 2

    /// Offset added to a signal number to form the process exit status.
    private static let signalExitStatusBase: Int32 = 128

    /// Signal sources kept alive for the life of the process.
    private static let sources = LockedSources()

    /// Install the atexit handler and the signal handlers. Call once at
    /// startup, before the server loop starts.
    static func install() {
        atexit {
            HeldInputReleaseOnExit.releaseAll(reason: "server exit", session: .shared,
                                              interruption: .shared)
        }
        let queue = DispatchQueue(label: "mirroir.held-input.signals")
        for signalNumber in terminationSignals {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler {
                Darwin.exit(terminate(signal: signalNumber, session: .shared, interruption: .shared))
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Release everything held: stop the running playbacks and wait until
    /// each ran its own release, then lift the touch contact. Playbacks go
    /// first so a drag frame never follows the touch release.
    static func releaseAll(reason: String, session: TouchSession,
                           interruption: PlaybackInterruption) {
        if !interruption.interruptAndWait(timeout: playbackReleaseTimeout) {
            DebugLog.persist("exit", "a playback was still running after \(playbackReleaseTimeout)s: \(reason)")
        }
        session.releaseIfHeld(reason: reason)
    }

    /// Handle termination signal `signal`: release everything held and
    /// return the exit status the process must end with.
    static func terminate(signal: Int32, session: TouchSession,
                          interruption: PlaybackInterruption) -> Int32 {
        releaseAll(reason: "signal \(signal)", session: session, interruption: interruption)
        return signalExitStatusBase + signal
    }

    /// Retains the installed signal sources.
    private final class LockedSources: @unchecked Sendable {
        private let lock = NSLock()
        private var retained: [any DispatchSourceSignal] = []

        func append(_ source: any DispatchSourceSignal) {
            lock.withLock { retained.append(source) }
        }
    }
}
