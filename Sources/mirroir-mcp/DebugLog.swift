// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Shared debug logger that writes to stderr and appends pid-tagged lines to ~/.mirroir-mcp/debug.log.
// ABOUTME: Startup lines always persist; verbose lines require --debug or MIRROIR_DEBUG. No process truncates the log.

import Darwin
import Foundation
import HelperLib
import os

/// Shared debug logger used across the MCP server.
/// Startup messages always persist to the log file via `persist()`.
/// Verbose per-request messages only write when `enabled` is true via `log()`.
///
/// Several servers can run at once (a client often starts two, and a local
/// debug server may run beside them), all writing the same file. So the log is
/// append-only: every line names the process that wrote it, each write is one
/// `O_APPEND` call, and a starting process never truncates the file. It only
/// moves a log past `EnvConfig.debugLogMaxBytes` to `debug.log.1`; a process
/// still writing then continues in the new file.
enum DebugLog {
    /// Whether verbose debug logging is active. Set once at startup.
    private static let _enabled = OSAllocatedUnfairLock(initialState: false)
    static var enabled: Bool {
        get { _enabled.withLock { $0 } }
        set { _enabled.withLock { $0 = newValue } }
    }

    /// Whether a command line or the environment asks for verbose logging:
    /// `--debug` anywhere in `arguments`, or `debugLogging` on in the settings.
    static func isRequested(arguments: [String], setting: Bool = EnvConfig.debugLogging) -> Bool {
        arguments.contains(CLIDispatch.debugOption) || setting
    }

    /// Path to the debug log file inside the global config directory.
    static var logPath: String {
        PermissionPolicy.globalConfigDir + "/debug.log"
    }

    /// Where a rotated log goes.
    static var rotatedLogPath: String { logPath + ".1" }

    /// ISO-style timestamp formatter (HH:mm:ss.SSS) for log lines.
    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt
    }()

    /// Current timestamp string for log output.
    private static var timestamp: String {
        timestampFormatter.string(from: Date())
    }

    /// One log line: the tag, the time and the process that wrote it.
    static func line(tag: String, time: String, pid: pid_t, message: String) -> String {
        "[\(tag) \(time) pid \(pid)] \(message)\n"
    }

    /// Prepare the debug log at startup: rotate it when it has grown past the
    /// limit, then mark where this process starts. Earlier processes' lines,
    /// and those of servers still running, are kept.
    static func start() {
        let dir = PermissionPolicy.globalConfigDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        rotateIfLarger(than: EnvConfig.debugLogMaxBytes, path: logPath, rotatedPath: rotatedLogPath)
        let mode = enabled ? "verbose" : "startup lines only"
        appendToFile("\n--- pid \(getpid()) started \(timestamp) (\(mode)) ---\n", path: logPath)
    }

    /// Move the log at `path` to `rotatedPath` when it holds more than
    /// `maxBytes`, replacing an earlier rotated log. Nothing is truncated: a
    /// process that writes after the move creates a new file at `path`.
    static func rotateIfLarger(than maxBytes: Int, path: String, rotatedPath: String) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              size > maxBytes else { return }
        // rename(2) replaces the destination atomically.
        rename(path, rotatedPath)
    }

    /// Write a tagged line to the log file and stderr unconditionally.
    /// Use for startup messages that must always be recorded.
    static func persist(_ tag: String, _ message: String) {
        let text = line(tag: tag, time: timestamp, pid: getpid(), message: message)
        fputs(text, stderr)
        appendToFile(text, path: logPath)
    }

    /// Write a tagged debug line to stderr and the log file when verbose logging is on.
    /// Use for per-request diagnostic messages gated by --debug.
    static func log(_ tag: String, _ message: String) {
        guard enabled else { return }
        let text = line(tag: tag, time: timestamp, pid: getpid(), message: message)
        fputs(text, stderr)
        appendToFile(text, path: logPath)
    }

    /// Append `text` to the file at `path`, creating it when absent, in one
    /// `O_APPEND` write so lines from several processes never overwrite each other.
    static func appendToFile(_ text: String, path: String) {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}
