// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unix stream socket server accepting JSON commands from the MCP server.
// ABOUTME: Manages socket lifecycle and client connections; delegates command handling to CommandHandlers.

import CoreGraphics
import Darwin
import Foundation
import HelperLib
import SystemConfiguration

/// Path where the helper listens for commands from the MCP server.
let helperSocketPath = "/var/run/mirroir-helper.sock"

/// Listens on a Unix stream socket and dispatches JSON commands to the Karabiner client.
/// Each command is a single line of newline-delimited JSON.
///
/// Supported commands:
/// - click: CGWarp to (x,y), Karabiner button down/up, restore cursor
/// - long_press: CGWarp to (x,y), Karabiner button down, hold for duration, button up
/// - double_tap: CGWarp to (x,y), two rapid Karabiner click cycles
/// - drag: CGWarp + button down, hold for drag recognition, slow interpolated move, button up
/// - type: Map characters to HID keycodes, send via Karabiner keyboard
/// - press_key: Send a special key (return, escape, arrows) via Karabiner keyboard
/// - shake: Send Ctrl+Cmd+Z via Karabiner keyboard (triggers iOS shake gesture)
/// - swipe: CGWarp + Karabiner button down, interpolate movement, button up
/// - move: Send relative mouse movement via Karabiner pointing
/// - status: Report device readiness
final class CommandServer {
    let karabiner: any KarabinerProviding
    // SAFETY: listenFd and running are accessed from the accept loop thread and stop().
    // stop() is only called from the signal handler which immediately calls exit(0),
    // so there is no concurrent access with the accept loop.
    private var listenFd: Int32 = -1
    var running = false

    init(karabiner: any KarabinerProviding) {
        self.karabiner = karabiner
    }

    deinit {
        stop()
    }

    /// Start listening for connections. Blocks the calling thread.
    func start() throws {
        // Clean up stale socket file
        unlink(helperSocketPath)

        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            throw HelperError.socketFailed(errno: errno)
        }

        var addr = makeUnixAddress(path: helperSocketPath)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(listenFd)
            throw HelperError.bindFailed(errno: errno)
        }

        // Restrict socket access to the console user (the person sitting at the Mac).
        // This prevents other system daemons and non-console users from sending commands.
        if let (uid, gid) = Self.resolveConsoleUID() {
            chmod(helperSocketPath, 0o600)
            chown(helperSocketPath, uid, gid)
            logHelper("Socket owned by console user uid=\(uid) gid=\(gid) mode=0600")
        } else {
            // No console user (e.g. loginwindow) — fail closed with no access
            chmod(helperSocketPath, 0o000)
            logHelper("No console user detected, socket mode=0000 (fail-closed)")
        }

        guard listen(listenFd, 4) == 0 else {
            Darwin.close(listenFd)
            throw HelperError.listenFailed(errno: errno)
        }

        running = true
        logHelper("Listening on \(helperSocketPath)")

        // Accept loop
        while running {
            let clientFd = accept(listenFd, nil, nil)
            guard clientFd >= 0 else {
                if !running { break }
                logHelper("accept() failed: \(String(cString: strerror(errno)))")
                continue
            }

            // Authenticate the connecting peer via getpeereid.
            // Re-resolve console UID on each connection to handle fast user switching.
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            if getpeereid(clientFd, &peerUID, &peerGID) == 0 {
                let consoleUID = Self.resolveConsoleUID()?.uid
                let allowed = peerUID == 0 || (consoleUID != nil && peerUID == consoleUID)
                if !allowed {
                    logHelper("Rejected connection from uid=\(peerUID) (console uid=\(consoleUID.map { String($0) } ?? "none"))")
                    Darwin.close(clientFd)
                    continue
                }
                logHelper("Accepted connection from uid=\(peerUID)")
            }

            // Set receive and send timeouts so the accept loop doesn't get stuck
            // when a client disconnects uncleanly or stops reading responses.
            var timeout = timeval(tv_sec: Int(EnvConfig.clientRecvTimeoutSec), tv_usec: 0)
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))

            // Handle one client at a time (MCP server is the only client).
            // defer ensures the fd is closed even if handleClient throws or returns early.
            defer { Darwin.close(clientFd) }
            handleClient(fd: clientFd)
        }
    }

    /// Resolve the UID and GID of the macOS console user (the person logged in at the physical
    /// display) via `SCDynamicStoreCopyConsoleUser`. Returns `nil` when nobody is logged in
    /// (loginwindow reports uid 0xFFFFFFFF).
    static func resolveConsoleUID() -> (uid: uid_t, gid: gid_t)? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              !name.isEmpty,
              uid != 0xFFFF_FFFF else {
            return nil
        }
        return (uid, gid)
    }

    /// Stop the server.
    func stop() {
        running = false
        if listenFd >= 0 {
            Darwin.close(listenFd)
            listenFd = -1
        }
        unlink(helperSocketPath)
    }

    // MARK: - Client Handling

    /// Maximum size of a single command line (64 KB). Lines exceeding this are
    /// rejected to prevent unbounded memory growth from malformed input.
    private static let maxCommandSize = 65_536

    /// Read newline-delimited JSON from the client and dispatch commands.
    func handleClient(fd: Int32) {
        logHelper("Client connected")
        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)
        let maxIdleTimeouts = EnvConfig.clientIdleMaxTimeouts
        var consecutiveIdleTimeouts = 0

        while running {
            let bytesRead = recv(fd, &readBuf, readBuf.count, 0)
            if bytesRead == 0 { break } // Clean disconnect
            if bytesRead < 0 {
                let recvErrno = errno
                if recvErrno == EAGAIN || recvErrno == EWOULDBLOCK {
                    consecutiveIdleTimeouts += 1
                    if consecutiveIdleTimeouts >= maxIdleTimeouts {
                        let idleSec = consecutiveIdleTimeouts * EnvConfig.clientRecvTimeoutSec
                        logHelper("Client idle for \(idleSec)s (\(consecutiveIdleTimeouts) timeouts), dropping")
                        break
                    }
                    continue
                }
                logHelper("recv() failed: \(String(cString: strerror(recvErrno)))")
                break
            }
            consecutiveIdleTimeouts = 0

            buffer.append(contentsOf: readBuf[0..<bytesRead])

            // Guard against unbounded buffer growth from missing newlines
            if buffer.count > Self.maxCommandSize && !buffer.contains(0x0A) {
                logHelper("Command exceeds \(Self.maxCommandSize) bytes without newline, dropping")
                buffer.removeAll()
                continue
            }

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                guard !lineData.isEmpty else { continue }

                let response = processCommand(data: lineData)
                let responseData = response + Data([0x0A]) // newline delimiter
                let sent = responseData.withUnsafeBytes { buf in
                    send(fd, buf.baseAddress, buf.count, 0)
                }
                if sent < 0 {
                    let sendErrno = errno
                    logHelper("send() failed: \(String(cString: strerror(sendErrno)))")
                    if sendErrno == EPIPE || sendErrno == ECONNRESET {
                        break
                    }
                }
            }
        }
        logHelper("Client disconnected")
    }

    // MARK: - JSON Response Helpers

    /// Fallback response used when JSON serialization itself fails.
    static let fallbackErrorData = Data(#"{"ok":false,"error":"internal serialization error"}"#.utf8)

    func makeOkResponse() -> Data {
        return safeJSON(["ok": true])
    }

    func makeErrorResponse(_ message: String) -> Data {
        return safeJSON(["ok": false, "error": message])
    }

    /// Serialize a dictionary to JSON, returning a hardcoded error response on failure.
    func safeJSON(_ obj: [String: Any]) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: obj)
        } catch {
            logHelper("JSON serialization failed: \(error)")
            return Self.fallbackErrorData
        }
    }
}

// MARK: - Errors

enum HelperError: Error, CustomStringConvertible {
    case socketFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)

    var description: String {
        switch self {
        case .socketFailed(let e):
            return "Failed to create socket: \(String(cString: strerror(e)))"
        case .bindFailed(let e):
            return "Failed to bind \(helperSocketPath): \(String(cString: strerror(e)))"
        case .listenFailed(let e):
            return "Failed to listen: \(String(cString: strerror(e)))"
        }
    }
}

/// Log to stderr.
func logHelper(_ message: String) {
    FileHandle.standardError.write(Data("[CommandServer] \(message)\n".utf8))
}
