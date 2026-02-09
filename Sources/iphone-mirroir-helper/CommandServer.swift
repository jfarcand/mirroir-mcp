// ABOUTME: Unix stream socket server accepting JSON commands from the MCP server.
// ABOUTME: Dispatches click/type/swipe/move/status commands to KarabinerClient with CGWarp cursor control.

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
/// - type: Map characters to HID keycodes, send via Karabiner keyboard
/// - press_key: Send a special key (return, escape, arrows) via Karabiner keyboard
/// - swipe: CGWarp + Karabiner button down, interpolate movement, button up
/// - move: Send relative mouse movement via Karabiner pointing
/// - status: Report device readiness
final class CommandServer {
    private let karabiner: KarabinerClient
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
        let staffGroupID: gid_t = 20 // macOS built-in staff group
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
                _ = responseData.withUnsafeBytes { buf in
                    send(fd, buf.baseAddress, buf.count, 0)
                }
            }
        }
        logHelper("Client disconnected")
    }

    /// Parse and execute a JSON command, returning the JSON response.
    private func processCommand(data: Data) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String
        else {
            return makeErrorResponse("Invalid JSON command")
        }

        switch action {
        case "click":
            return handleClick(json)
        case "type":
            return handleType(json)
        case "swipe":
            return handleSwipe(json)
        case "move":
            return handleMove(json)
        case "press_key":
            return handlePressKey(json)
        case "status":
            return handleStatus()
        default:
            return makeErrorResponse("Unknown action: \(action)")
        }
    }

    // MARK: - Command Handlers

    /// Click at screen-absolute coordinates.
    /// Disconnects physical mouse, warps to target, sends Karabiner click, restores cursor.
    /// CGAssociateMouseAndMouseCursorPosition(false) prevents the user's physical mouse
    /// from interfering with the programmatic cursor placement during the operation.
    private func handleClick(_ json: [String: Any]) -> Data {
        guard let x = (json["x"] as? NSNumber)?.doubleValue,
              let y = (json["y"] as? NSNumber)?.doubleValue
        else {
            return makeErrorResponse("click requires x and y (numbers)")
        }

        guard karabiner.isPointingReady else {
            return makeErrorResponse("Karabiner pointing device not ready")
        }

        let target = CGPoint(x: x, y: y)

        // Save current cursor position
        let savedPosition = CGEvent(source: nil)?.location ?? .zero

        // Disconnect physical mouse so user movement doesn't interfere
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))

        // Warp system cursor to target
        CGWarpMouseCursorPosition(target)
        usleep(10_000) // 10ms for cursor settle

        // Small Karabiner nudge to sync virtual device with warped cursor
        var nudgeRight = PointingInput()
        nudgeRight.x = 1
        karabiner.postPointingReport(nudgeRight)
        usleep(5_000)

        var nudgeBack = PointingInput()
        nudgeBack.x = -1
        karabiner.postPointingReport(nudgeBack)
        usleep(10_000)

        // Button down
        var down = PointingInput()
        down.buttons = 0x01
        karabiner.postPointingReport(down)
        usleep(80_000) // 80ms hold for reliable tap

        // Button up
        var up = PointingInput()
        up.buttons = 0x00
        karabiner.postPointingReport(up)
        usleep(10_000)

        // Restore cursor position and reconnect physical mouse
        CGWarpMouseCursorPosition(savedPosition)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        return makeOkResponse()
    }

    /// Type text by mapping each character to HID keycodes.
    /// Characters without a US QWERTY HID mapping are skipped and reported in the response.
    ///
    /// When `focus_x`/`focus_y` are provided, clicks those screen-absolute coordinates
    /// first to give the target window keyboard focus. This happens atomically within
    /// the same command — no IPC round-trip gap where another window could steal focus.
    private func handleType(_ json: [String: Any]) -> Data {
        guard let text = json["text"] as? String, !text.isEmpty else {
            return makeErrorResponse("type requires non-empty text (string)")
        }

        guard karabiner.isKeyboardReady else {
            return makeErrorResponse("Karabiner keyboard device not ready")
        }

        // Atomic focus: click the title bar to give the window keyboard focus,
        // keep the cursor parked there with physical mouse disconnected during
        // the entire typing operation. Only restore cursor after all typing is done.
        var savedPosition: CGPoint = .zero
        let hasFocusClick: Bool
        if let focusX = (json["focus_x"] as? NSNumber)?.doubleValue,
           let focusY = (json["focus_y"] as? NSNumber)?.doubleValue,
           karabiner.isPointingReady {
            hasFocusClick = true
            let target = CGPoint(x: focusX, y: focusY)
            savedPosition = CGEvent(source: nil)?.location ?? .zero
            logHelper("handleType: focus click at (\(focusX), \(focusY)), cursor saved at (\(Int(savedPosition.x)), \(Int(savedPosition.y)))")

            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
            CGWarpMouseCursorPosition(target)
            usleep(10_000)

            // Karabiner nudge to sync virtual device with warped cursor
            var nudgeRight = PointingInput()
            nudgeRight.x = 1
            karabiner.postPointingReport(nudgeRight)
            usleep(5_000)
            var nudgeBack = PointingInput()
            nudgeBack.x = -1
            karabiner.postPointingReport(nudgeBack)
            usleep(10_000)

            // Click down + up to give the window focus
            var down = PointingInput()
            down.buttons = 0x01
            karabiner.postPointingReport(down)
            usleep(80_000)
            var up = PointingInput()
            up.buttons = 0x00
            karabiner.postPointingReport(up)

            usleep(200_000) // 200ms for focus to settle before typing
            // Cursor stays on target, physical mouse stays disconnected
        } else {
            hasFocusClick = false
            logHelper("handleType: no focus click (focus_x=\(String(describing: json["focus_x"])), focus_y=\(String(describing: json["focus_y"])), pointing=\(karabiner.isPointingReady))")
        }

        var skippedChars = [String]()

        for char in text {
            guard let mapping = HIDKeyMap.lookup(char) else {
                let codepoint = char.unicodeScalars.first.map { "U+\(String($0.value, radix: 16, uppercase: true))" } ?? "?"
                logHelper("No HID mapping for character: '\(char)' (\(codepoint))")
                skippedChars.append(String(char))
                continue
            }

            karabiner.typeKey(keycode: mapping.keycode, modifiers: mapping.modifiers)
            usleep(15_000) // 15ms between keystrokes
        }

        // Restore cursor and reconnect physical mouse after all typing is done
        if hasFocusClick {
            CGWarpMouseCursorPosition(savedPosition)
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        }

        if skippedChars.isEmpty {
            return makeOkResponse()
        }
        return safeJSON([
            "ok": true,
            "skipped_characters": skippedChars.joined(),
            "warning": "Some characters have no US QWERTY HID mapping and were not typed",
        ])
    }

    /// Swipe from one screen-absolute point to another.
    /// Disconnects physical mouse, warps cursor, interpolates movement, restores cursor.
    private func handleSwipe(_ json: [String: Any]) -> Data {
        guard let fromX = (json["from_x"] as? NSNumber)?.doubleValue,
              let fromY = (json["from_y"] as? NSNumber)?.doubleValue,
              let toX = (json["to_x"] as? NSNumber)?.doubleValue,
              let toY = (json["to_y"] as? NSNumber)?.doubleValue
        else {
            return makeErrorResponse("swipe requires from_x, from_y, to_x, to_y (numbers)")
        }

        let durationMs = (json["duration_ms"] as? NSNumber)?.intValue ?? 300

        guard karabiner.isPointingReady else {
            return makeErrorResponse("Karabiner pointing device not ready")
        }

        let savedPosition = CGEvent(source: nil)?.location ?? .zero

        // Disconnect physical mouse so user movement doesn't interfere
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))

        // Warp to start position
        CGWarpMouseCursorPosition(CGPoint(x: fromX, y: fromY))
        usleep(10_000)

        // Sync Karabiner with nudge
        var nudge = PointingInput()
        nudge.x = 1
        karabiner.postPointingReport(nudge)
        usleep(5_000)
        nudge.x = -1
        karabiner.postPointingReport(nudge)
        usleep(10_000)

        // Button down
        var down = PointingInput()
        down.buttons = 0x01
        karabiner.postPointingReport(down)
        usleep(30_000)

        // Interpolate movement
        let steps = 40
        let totalDx = toX - fromX
        let totalDy = toY - fromY
        let stepDelayUs = UInt32(max(durationMs, 1) * 1000 / steps)

        for i in 1...steps {
            let progress = Double(i) / Double(steps)
            let targetX = fromX + totalDx * progress
            let targetY = fromY + totalDy * progress

            // Warp cursor along the path
            CGWarpMouseCursorPosition(CGPoint(x: targetX, y: targetY))

            // Send small relative movement to keep Karabiner in sync
            let dx = Int8(clamping: Int(totalDx / Double(steps)))
            let dy = Int8(clamping: Int(totalDy / Double(steps)))
            var move = PointingInput()
            move.buttons = 0x01
            move.x = dx
            move.y = dy
            karabiner.postPointingReport(move)
            usleep(stepDelayUs)
        }

        // Button up
        var up = PointingInput()
        up.buttons = 0x00
        karabiner.postPointingReport(up)
        usleep(10_000)

        // Restore cursor and reconnect physical mouse
        CGWarpMouseCursorPosition(savedPosition)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        return makeOkResponse()
    }

    /// Send relative mouse movement.
    private func handleMove(_ json: [String: Any]) -> Data {
        guard let dx = (json["dx"] as? NSNumber)?.int8Value,
              let dy = (json["dy"] as? NSNumber)?.int8Value
        else {
            return makeErrorResponse("move requires dx and dy (integers)")
        }

        guard karabiner.isPointingReady else {
            return makeErrorResponse("Karabiner pointing device not ready")
        }

        karabiner.moveMouse(dx: dx, dy: dy)
        return makeOkResponse()
    }

    /// Press a special key (return, escape, arrows, etc.) with optional modifiers.
    /// Uses `HIDSpecialKeyMap` to look up the USB HID keycode, then sends via Karabiner.
    private func handlePressKey(_ json: [String: Any]) -> Data {
        guard let keyName = json["key"] as? String else {
            return makeErrorResponse("press_key requires key (string)")
        }

        guard karabiner.isKeyboardReady else {
            return makeErrorResponse("Karabiner keyboard device not ready")
        }

        guard let hidKeyCode = HIDSpecialKeyMap.hidKeyCode(for: keyName) else {
            let supported = HIDSpecialKeyMap.supportedKeys.joined(separator: ", ")
            return makeErrorResponse("Unknown key: \"\(keyName)\". Supported: \(supported)")
        }

        let modifierNames = json["modifiers"] as? [String] ?? []
        let modifiers = HIDSpecialKeyMap.modifiers(from: modifierNames)

        karabiner.typeKey(keycode: hidKeyCode, modifiers: modifiers)
        return makeOkResponse()
    }

    /// Return current device readiness status.
    private func handleStatus() -> Data {
        let status: [String: Any] = [
            "ok": karabiner.isConnected,
            "keyboard_ready": karabiner.isKeyboardReady,
            "pointing_ready": karabiner.isPointingReady,
        ]
        return safeJSON(status)
    }

    // MARK: - JSON Response Helpers

    /// Fallback response used when JSON serialization itself fails.
    private static let fallbackErrorData = Data(#"{"ok":false,"error":"internal serialization error"}"#.utf8)

    private func makeOkResponse() -> Data {
        return safeJSON(["ok": true])
    }

    private func makeErrorResponse(_ message: String) -> Data {
        return safeJSON(["ok": false, "error": message])
    }

    /// Serialize a dictionary to JSON, returning a hardcoded error response on failure.
    private func safeJSON(_ obj: [String: Any]) -> Data {
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
private func logHelper(_ message: String) {
    FileHandle.standardError.write(Data("[CommandServer] \(message)\n".utf8))
}
