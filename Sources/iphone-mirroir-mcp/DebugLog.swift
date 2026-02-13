// ABOUTME: Shared debug logger that writes to stderr and ~/.iphone-mirroir-mcp/debug.log.
// ABOUTME: Startup lines always persist to the log file; verbose lines require --debug.

import Foundation
import HelperLib

/// Shared debug logger used across the MCP server.
/// Startup messages always persist to the log file via `persist()`.
/// Verbose per-request messages only write when `enabled` is true via `log()`.
enum DebugLog {
    /// Whether verbose debug logging is active. Set once at startup from --debug flag,
    /// before any concurrent access occurs.
    nonisolated(unsafe) static var enabled = false

    /// Path to the debug log file inside the global config directory.
    static var logPath: String {
        PermissionPolicy.globalConfigDir + "/debug.log"
    }

    /// Truncate the debug log file. Called once at startup.
    /// Always creates the config directory and file so startup lines can be written.
    static func reset() {
        let dir = PermissionPolicy.globalConfigDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logPath, contents: nil)
    }

    /// Write a tagged line to the log file and stderr unconditionally.
    /// Use for startup messages that must always be recorded.
    static func persist(_ tag: String, _ message: String) {
        let line = "[\(tag)] \(message)\n"
        fputs(line, stderr)
        appendToFile(line)
    }

    /// Write a tagged debug line to stderr and the log file when verbose logging is on.
    /// Use for per-request diagnostic messages gated by --debug.
    static func log(_ tag: String, _ message: String) {
        guard enabled else { return }
        let line = "[\(tag)] \(message)\n"
        fputs(line, stderr)
        appendToFile(line)
    }

    /// Append a line to the log file, creating it if it doesn't exist.
    private static func appendToFile(_ line: String) {
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath,
                                           contents: Data(line.utf8))
        }
    }
}
