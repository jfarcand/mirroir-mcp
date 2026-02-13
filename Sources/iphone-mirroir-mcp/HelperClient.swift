// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unix socket client connecting to the privileged Karabiner helper daemon.
// ABOUTME: Sends JSON commands (click, type, swipe) and receives JSON responses over IPC.

import Darwin
import Foundation

/// Client for communicating with the iphone-mirroir-helper LaunchDaemon.
/// Connects to the helper's Unix stream socket and sends newline-delimited JSON commands.
///
/// The helper handles all Karabiner virtual HID interaction (which requires root).
/// This client runs in the unprivileged MCP server process.
final class HelperClient: @unchecked Sendable {
    private let socketPath = "/var/run/iphone-mirroir-helper.sock"
    private var socketFd: Int32 = -1

    /// Whether the helper daemon is reachable and devices are ready.
    var isAvailable: Bool {
        if socketFd < 0 {
            _ = connect()
        }
        guard socketFd >= 0 else { return false }

        // Quick status check
        guard let response = sendCommand(["action": "status"]) else {
            disconnect()
            return false
        }
        return response["ok"] as? Bool ?? false
    }

    deinit {
        disconnect()
    }

    // MARK: - Public API

    /// Click at screen-absolute coordinates.
    func click(x: Double, y: Double) -> Bool {
        let response = sendCommandWithReconnect([
            "action": "click",
            "x": x,
            "y": y,
        ])
        return response?["ok"] as? Bool ?? false
    }

    /// Long press at screen-absolute coordinates for the specified duration.
    func longPress(x: Double, y: Double, durationMs: Int = 500) -> Bool {
        let response = sendCommandWithReconnect([
            "action": "long_press",
            "x": x,
            "y": y,
            "duration_ms": durationMs,
        ])
        return response?["ok"] as? Bool ?? false
    }

    /// Double-tap at screen-absolute coordinates.
    func doubleTap(x: Double, y: Double) -> Bool {
        let response = sendCommandWithReconnect([
            "action": "double_tap",
            "x": x,
            "y": y,
        ])
        return response?["ok"] as? Bool ?? false
    }

    /// Drag from one point to another with sustained contact.
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int = 1000) -> Bool {
        let response = sendCommandWithReconnect([
            "action": "drag",
            "from_x": fromX,
            "from_y": fromY,
            "to_x": toX,
            "to_y": toY,
            "duration_ms": durationMs,
        ])
        return response?["ok"] as? Bool ?? false
    }

    /// Trigger a shake gesture on the mirrored iPhone.
    func shake() -> Bool {
        let response = sendCommandWithReconnect(["action": "shake"])
        return response?["ok"] as? Bool ?? false
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

        let response = sendCommandWithReconnect(command)
        return response?["ok"] as? Bool ?? false
    }

    /// Swipe between two screen-absolute points.
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int = 300) -> Bool {
        let response = sendCommandWithReconnect([
            "action": "swipe",
            "from_x": fromX,
            "from_y": fromY,
            "to_x": toX,
            "to_y": toY,
            "duration_ms": durationMs,
        ])
        return response?["ok"] as? Bool ?? false
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
              npx iphone-mirroir-mcp setup\n\
            Screenshots and menu actions (Home, Spotlight, App Switcher) still work without it.
            """
    }

    // MARK: - Connection Management

    private func connect() -> Bool {
        socketFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
            for i in 0..<min(pathBytes.count, sunPath.count - 1) {
                sunPath[i] = pathBytes[i]
            }
            sunPath[min(pathBytes.count, sunPath.count - 1)] = 0
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socketFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result != 0 {
            Darwin.close(socketFd)
            socketFd = -1
            return false
        }

        // Set send/receive timeouts (5 seconds — type commands with long text
        // can take several hundred milliseconds for the helper to process)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socketFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        return true
    }

    private func disconnect() {
        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
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
        guard socketFd >= 0 || connect() else { return nil }

        guard var data = try? JSONSerialization.data(withJSONObject: command) else { return nil }
        data.append(0x0A) // newline delimiter

        // Send
        let sent = data.withUnsafeBytes { buf in
            send(socketFd, buf.baseAddress, buf.count, 0)
        }
        guard sent == data.count else { return nil }

        // Read response (expect single line)
        var responseBuf = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(socketFd, &responseBuf, responseBuf.count, 0)
        guard bytesRead > 0 else { return nil }

        // Find newline delimiter in response
        let responseData: Data
        if let newlineIdx = responseBuf[0..<bytesRead].firstIndex(of: 0x0A) {
            responseData = Data(responseBuf[0..<newlineIdx])
        } else {
            responseData = Data(responseBuf[0..<bytesRead])
        }

        return try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    }
}
