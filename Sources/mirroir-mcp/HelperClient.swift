// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unix socket client connecting to the privileged Karabiner helper daemon.
// ABOUTME: Sends JSON commands (click, type, swipe) and receives JSON responses over IPC.

import Darwin
import Foundation
import HelperLib
import os

/// Client for communicating with the mirroir-helper LaunchDaemon.
/// Connects to the helper's Unix stream socket and sends newline-delimited JSON commands.
///
/// The helper handles all Karabiner virtual HID interaction (which requires root).
/// This client runs in the unprivileged MCP server process.
final class HelperClient: Sendable {
    private let socketPath = "/var/run/mirroir-helper.sock"
    private let socketFd = OSAllocatedUnfairLock(initialState: Int32(-1))

    /// Whether the helper daemon is reachable and devices are ready.
    var isAvailable: Bool {
        if socketFd.withLock({ $0 }) < 0 {
            _ = connect()
        }
        guard socketFd.withLock({ $0 }) >= 0 else { return false }

        // Quick status check
        guard let response = sendCommand(["action": "status"]) else {
            disconnect()
            return false
        }
        return response["ok"] as? Bool ?? false
    }

    deinit {
        let fd = socketFd.withLock { $0 }
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    // MARK: - Public API

    /// Click at screen-absolute coordinates.
    func click(x: Double, y: Double) -> Bool {
        boolResult(["action": "click", "x": x, "y": y], tag: "click")
    }

    /// Long press at screen-absolute coordinates for the specified duration.
    func longPress(x: Double, y: Double, durationMs: Int = 500) -> Bool {
        boolResult(["action": "long_press", "x": x, "y": y, "duration_ms": durationMs], tag: "longPress")
    }

    /// Double-tap at screen-absolute coordinates.
    func doubleTap(x: Double, y: Double) -> Bool {
        boolResult(["action": "double_tap", "x": x, "y": y], tag: "doubleTap")
    }

    /// Drag from one point to another with sustained contact.
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int = 1000) -> Bool {
        boolResult([
            "action": "drag",
            "from_x": fromX, "from_y": fromY,
            "to_x": toX, "to_y": toY,
            "duration_ms": durationMs,
        ], tag: "drag")
    }

    /// Trigger a shake gesture on the mirrored iPhone.
    func shake() -> Bool {
        boolResult(["action": "shake"], tag: "shake")
    }

    /// Result of a type command from the helper, including skipped character info.
    struct TypeResponse {
        let ok: Bool
        let skippedCharacters: String
        let warning: String?
    }

    /// Type text via Karabiner virtual keyboard.
    /// When `focusX`/`focusY` are provided, the helper clicks those screen-absolute
    /// coordinates first to give the target window keyboard focus, then types
    /// atomically in the same command.
    func type(text: String, focusX: Double? = nil, focusY: Double? = nil) -> TypeResponse {
        var command: [String: Any] = [
            "action": "type",
            "text": text,
        ]
        if let fx = focusX, let fy = focusY {
            command["focus_x"] = fx
            command["focus_y"] = fy
        }

        guard let response = sendCommandWithReconnect(command) else {
            return TypeResponse(ok: false, skippedCharacters: "", warning: nil)
        }

        return TypeResponse(
            ok: response["ok"] as? Bool ?? false,
            skippedCharacters: response["skipped_characters"] as? String ?? "",
            warning: response["warning"] as? String
        )
    }

    /// Press a special key (return, escape, arrows, etc.) with optional modifiers
    /// via Karabiner virtual keyboard.
    func pressKey(key: String, modifiers: [String] = []) -> Bool {
        var command: [String: Any] = [
            "action": "press_key",
            "key": key,
        ]
        if !modifiers.isEmpty {
            command["modifiers"] = modifiers
        }
        return boolResult(command, tag: "pressKey")
    }

    /// Swipe between two screen-absolute points.
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int = 300) -> Bool {
        boolResult([
            "action": "swipe",
            "from_x": fromX, "from_y": fromY,
            "to_x": toX, "to_y": toY,
            "duration_ms": durationMs,
        ], tag: "swipe")
    }

    /// Get the helper's status including device readiness.
    func status() -> [String: Any]? {
        return sendCommandWithReconnect(["action": "status"])
    }

    /// Get an error message explaining that the helper is not available.
    var unavailableMessage: String {
        return """
            Helper daemon not running. Tap, type, and swipe require the helper daemon.\n\
            Run this in your terminal to complete setup:\n\
              npx mirroir-mcp setup\n\
            Screenshots and menu actions (Home, Spotlight, App Switcher) still work without it.
            """
    }

    // MARK: - Private Helpers

    /// Extract a boolean ok result from a command response, logging errors.
    private func boolResult(_ command: [String: Any], tag: String) -> Bool {
        guard let response = sendCommandWithReconnect(command) else {
            DebugLog.log("HelperClient", "\(tag): no response from helper")
            return false
        }
        let ok = response["ok"] as? Bool ?? false
        if !ok {
            let error = response["error"] as? String ?? "unknown error"
            DebugLog.log("HelperClient", "\(tag): helper returned error: \(error)")
        }
        return ok
    }

    // MARK: - Connection Management

    private func connect() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = makeUnixAddress(path: socketPath)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result != 0 {
            Darwin.close(fd)
            return false
        }

        // Set send/receive timeouts (5 seconds — type commands with long text
        // can take several hundred milliseconds for the helper to process)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        socketFd.withLock { $0 = fd }
        return true
    }

    private func disconnect() {
        let fd = socketFd.withLock { fd -> Int32 in
            let old = fd
            fd = -1
            return old
        }
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    // MARK: - Command Sending

    /// Send a command with automatic reconnection on failure.
    private func sendCommandWithReconnect(_ command: [String: Any]) -> [String: Any]? {
        // Try once, reconnect if failed, try again
        if let response = sendCommand(command) {
            return response
        }
        disconnect()
        guard connect() else { return nil }
        return sendCommand(command)
    }

    /// Send a JSON command and read the JSON response.
    private func sendCommand(_ command: [String: Any]) -> [String: Any]? {
        let fd = socketFd.withLock { $0 }
        guard fd >= 0 || connect() else { return nil }
        let activeFd = socketFd.withLock { $0 }
        guard activeFd >= 0 else { return nil }

        var data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: command)
        } catch {
            DebugLog.log("HelperClient", "JSON serialization failed for command: \(error)")
            return nil
        }
        data.append(0x0A) // newline delimiter

        // Send
        let sent = data.withUnsafeBytes { buf in
            send(activeFd, buf.baseAddress, buf.count, 0)
        }
        guard sent == data.count else { return nil }

        // Read response, looping until a newline delimiter arrives or EOF.
        // Cap at 64KB to match the server's maxCommandSize limit.
        let maxResponseSize = 65_536
        var responseBuffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)

        while responseBuffer.count < maxResponseSize {
            let bytesRead = recv(activeFd, &readBuf, readBuf.count, 0)
            if bytesRead == 0 { break } // EOF
            if bytesRead < 0 { return nil } // error or timeout

            responseBuffer.append(contentsOf: readBuf[0..<bytesRead])

            if responseBuffer.contains(0x0A) { break }
        }

        guard !responseBuffer.isEmpty else { return nil }

        // Extract first complete line (up to newline delimiter)
        let responseData: Data
        if let newlineIdx = responseBuffer.firstIndex(of: 0x0A) {
            responseData = Data(responseBuffer[responseBuffer.startIndex..<newlineIdx])
        } else {
            responseData = responseBuffer
        }

        do {
            return try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        } catch {
            DebugLog.log("HelperClient", "JSON response parse failed: \(error)")
            return nil
        }
    }
}
