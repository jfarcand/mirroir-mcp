// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Detects when the server binary has been rebuilt and self-reloads via execv().
// ABOUTME: Preserves PID and stdio file descriptors so the MCP client stays connected.

import Darwin
import Foundation

/// Checks the binary's mtime after each response and calls execv() to reload
/// when the binary on disk is newer than when the process started.
///
/// Checks the binary's mtime after each response and calls execv() to reload
/// when the binary on disk is newer than when the process started.
///
/// Hot-reload is opt-in via `--hot-reload-enabled`. When active, the server
/// re-execs only when the binary file has been replaced on disk (mtime
/// changed). Killing the process (SIGTERM, SIGINT, SIGKILL) does NOT
/// trigger a restart because those signals bypass the mtime check.
/// Crash recovery (`--restart-on-crash`) is a separate opt-in feature.
enum HotReload {

    /// Argument passed through execv so the restarted process skips the log reset.
    static let reloadFlag = "--hot-reload"

    /// Whether this process was started via hot-reload or crash restart.
    static let isReloaded: Bool = CommandLine.arguments.contains(reloadFlag)

    /// Whether hot-reload is enabled (opt-in via CLI flag).
    static let hotReloadEnabled: Bool = CommandLine.arguments.contains("--hot-reload-enabled")

    /// Whether crash-restart is enabled (opt-in via CLI flag).
    static let restartOnCrash: Bool = CommandLine.arguments.contains("--restart-on-crash")

    /// Mtime of the binary when the process started. Captured once on first access.
    private static let initialMtime: Date? = binaryMtime()

    /// Check whether the binary on disk is newer than when we started.
    /// Returns true when hot-reload is enabled and the binary has been replaced.
    /// Does NOT trigger the reload itself — the caller decides what to do.
    static func shouldReload() -> Bool {
        guard hotReloadEnabled else { return false }
        guard let initial = initialMtime,
              let current = binaryMtime(),
              current > initial else {
            return false
        }
        return true
    }

    /// Saved copy of argv for the signal handler (which cannot capture context).
    /// Populated once during `installCrashHandlers()`, read by `crashSignalHandler`.
    /// nonisolated(unsafe) because the signal handler reads this after setup.
    nonisolated(unsafe) static var savedArgv: [UnsafeMutablePointer<CChar>?] = []

    /// Install signal handlers for crash signals (SIGSEGV, SIGABRT, SIGBUS,
    /// SIGILL) that re-exec the binary via execv(). Only active when
    /// `--restart-on-crash` is passed. The MCP client stays connected because
    /// execv() preserves stdio file descriptors.
    static func installCrashHandlers() {
        guard restartOnCrash else { return }
        DebugLog.persist("startup", "Crash restart enabled (--restart-on-crash)")

        // Pre-allocate argv for the signal handler (strdup is async-signal-safe,
        // but Swift array operations are not — so build the array now).
        var args = CommandLine.arguments.filter { $0 != reloadFlag }
        args.append(reloadFlag)
        savedArgv = args.map { strdup($0) }
        savedArgv.append(nil)

        let crashSignals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL]
        for sig in crashSignals {
            signal(sig, crashSignalHandler)
        }
    }

    /// Re-exec the current binary, preserving PID and stdio so the MCP client
    /// stays connected. Used for hot-reload (debug builds).
    static func restartViaExecv() {
        fflush(stderr)

        // Build argv: original args (minus any prior --hot-reload) plus the flag.
        var args = CommandLine.arguments.filter { $0 != reloadFlag }
        args.append(reloadFlag)
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        execv(CommandLine.arguments[0], &cArgs)

        // execv only returns on failure
        DebugLog.persist("hot-reload", "execv failed: \(String(cString: strerror(errno)))")
    }

    /// Read the modification time of the running binary.
    private static func binaryMtime() -> Date? {
        let path = CommandLine.arguments[0]
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        return mtime
    }
}

/// C-compatible signal handler for crash recovery. Uses only async-signal-safe
/// functions (write, signal, execv, _exit). Called when SIGSEGV/SIGABRT/
/// SIGBUS/SIGILL is raised and --restart-on-crash is active.
private func crashSignalHandler(_ signum: Int32) {
    let msg = "[crash-restart] Caught signal, restarting via execv...\n"
    _ = msg.withCString { ptr in
        write(STDERR_FILENO, ptr, Int(strlen(ptr)))
    }

    // Reset to default so a double-fault terminates instead of looping.
    signal(signum, SIG_DFL)

    // Use the pre-allocated argv from installCrashHandlers().
    _ = HotReload.savedArgv.withUnsafeMutableBufferPointer { buf in
        execv(CommandLine.arguments[0], buf.baseAddress!)
    }

    // execv failed — terminate with the signal's exit code.
    _exit(128 + signum)
}
