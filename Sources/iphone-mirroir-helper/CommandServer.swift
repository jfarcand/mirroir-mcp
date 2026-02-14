// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unix stream socket server accepting JSON commands from the MCP server.
// ABOUTME: Manages socket lifecycle and client connections; delegates command handling to CommandHandlers.

import CoreGraphics
import Darwin
import Foundation
import HelperLib

/// Path where the helper listens for commands from the MCP server.
let helperSocketPath = "/var/run/iphone-mirroir-helper.sock"

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
    let karabiner: KarabinerClient
    private var listenFd: Int32 = -1
    private var running = false

    init(karabiner: KarabinerClient) {
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

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(helperSocketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
            for i in 0..<min(pathBytes.count, sunPath.count - 1) {
                sunPath[i] = pathBytes[i]
            }
            sunPath[min(pathBytes.count, sunPath.count - 1)] = 0
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(listenFd)
            throw HelperError.bindFailed(errno: errno)
        }

        // Allow local users (staff group) to connect. On macOS, all interactive
        // users are in the staff group, so this restricts access to local users
        // while preventing access from other system daemons.
        chmod(helperSocketPath, 0o660)
        // Set group to staff so the MCP server (running as a normal user) can connect
        let staffGroupID = gid_t(EnvConfig.staffGroupID)
        chown(helperSocketPath, 0, staffGroupID)

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

            // Handle one client at a time (MCP server is the only client)
            handleClient(fd: clientFd)
            Darwin.close(clientFd)
        }
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

    /// Read newline-delimited JSON from the client and dispatch commands.
    private func handleClient(fd: Int32) {
        logHelper("Client connected")
        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)

        while running {
            let bytesRead = recv(fd, &readBuf, readBuf.count, 0)
            if bytesRead <= 0 { break }

            buffer.append(contentsOf: readBuf[0..<bytesRead])

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
