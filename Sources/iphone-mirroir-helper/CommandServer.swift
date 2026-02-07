// ABOUTME: Unix stream socket server accepting JSON commands from the MCP server.
// ABOUTME: Dispatches click/type/swipe/move/status commands to KarabinerClient with CGWarp cursor control.

import CoreGraphics
import Darwin
import Foundation

/// Path where the helper listens for commands from the MCP server.
let helperSocketPath = "/var/run/iphone-mirroir-helper.sock"

/// Listens on a Unix stream socket and dispatches JSON commands to the Karabiner client.
/// Each command is a single line of newline-delimited JSON.
///
/// Supported commands:
/// - click: CGWarp to (x,y), Karabiner button down/up, restore cursor
/// - type: Map characters to HID keycodes, send via Karabiner keyboard
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

        // Allow any user to connect (MCP server runs as normal user)
        chmod(helperSocketPath, 0o666)

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
        case "status":
            return handleStatus()
        default:
            return makeErrorResponse("Unknown action: \(action)")
        }
    }

    // MARK: - Command Handlers

    /// Click at screen-absolute coordinates.
    /// Saves cursor position, warps to target, sends Karabiner click, restores cursor.
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

        // Restore cursor position
        CGWarpMouseCursorPosition(savedPosition)

        return makeOkResponse()
    }

    /// Type text by mapping each character to HID keycodes.
    private func handleType(_ json: [String: Any]) -> Data {
        guard let text = json["text"] as? String, !text.isEmpty else {
            return makeErrorResponse("type requires non-empty text (string)")
        }

        guard karabiner.isKeyboardReady else {
            return makeErrorResponse("Karabiner keyboard device not ready")
        }

        for char in text {
            guard let mapping = HIDKeyMap.lookup(char) else {
                logHelper("No HID mapping for character: '\(char)' (U+\(String(char.unicodeScalars.first!.value, radix: 16)))")
                continue
            }

            karabiner.typeKey(keycode: mapping.keycode, modifiers: mapping.modifiers)
            usleep(15_000) // 15ms between keystrokes
        }

        return makeOkResponse()
    }

    /// Swipe from one screen-absolute point to another.
    /// Warps cursor, holds button, interpolates movement, releases.
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

        // Restore cursor
        CGWarpMouseCursorPosition(savedPosition)

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

    /// Return current device readiness status.
    private func handleStatus() -> Data {
        let status: [String: Any] = [
            "ok": karabiner.isConnected,
            "keyboard_ready": karabiner.isKeyboardReady,
            "pointing_ready": karabiner.isPointingReady,
        ]
        return try! JSONSerialization.data(withJSONObject: status)
    }

    // MARK: - JSON Response Helpers

    private func makeOkResponse() -> Data {
        return try! JSONSerialization.data(withJSONObject: ["ok": true])
    }

    private func makeErrorResponse(_ message: String) -> Data {
        return try! JSONSerialization.data(withJSONObject: ["ok": false, "error": message])
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

// MARK: - HID Key Mapping

/// Maps Unicode characters to USB HID keyboard usage codes.
/// Reference: USB HID Usage Tables, section 10 (Keyboard/Keypad Page 0x07).
struct HIDKeyMapping {
    let keycode: UInt16
    let modifiers: KeyboardModifier
}

enum HIDKeyMap {
    /// Look up the HID keycode and required modifiers for a character.
    /// Returns nil for characters that have no direct HID mapping.
    static func lookup(_ char: Character) -> HIDKeyMapping? {
        return characterMap[char]
    }

    // US QWERTY keyboard layout mapping
    private static let characterMap: [Character: HIDKeyMapping] = {
        var map = [Character: HIDKeyMapping]()

        // Letters a-z (HID 0x04-0x1D)
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            map[c] = HIDKeyMapping(keycode: UInt16(0x04 + i), modifiers: [])
        }
        // Letters A-Z (same keycodes with shift)
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            map[c] = HIDKeyMapping(keycode: UInt16(0x04 + i), modifiers: .leftShift)
        }

        // Digits 1-9,0 (HID 0x1E-0x27)
        for (i, c) in "1234567890".enumerated() {
            map[c] = HIDKeyMapping(keycode: UInt16(0x1E + i), modifiers: [])
        }

        // Shifted digits
        let shiftedDigits: [(Character, UInt16)] = [
            ("!", 0x1E), ("@", 0x1F), ("#", 0x20), ("$", 0x21),
            ("%", 0x22), ("^", 0x23), ("&", 0x24), ("*", 0x25),
            ("(", 0x26), (")", 0x27),
        ]
        for (c, kc) in shiftedDigits {
            map[c] = HIDKeyMapping(keycode: kc, modifiers: .leftShift)
        }

        // Special characters
        map["\n"] = HIDKeyMapping(keycode: 0x28, modifiers: []) // Return
        map["\r"] = HIDKeyMapping(keycode: 0x28, modifiers: []) // Return
        map["\t"] = HIDKeyMapping(keycode: 0x2B, modifiers: []) // Tab
        map[" "]  = HIDKeyMapping(keycode: 0x2C, modifiers: []) // Space

        // Punctuation (unshifted)
        map["-"]  = HIDKeyMapping(keycode: 0x2D, modifiers: [])
        map["="]  = HIDKeyMapping(keycode: 0x2E, modifiers: [])
        map["["]  = HIDKeyMapping(keycode: 0x2F, modifiers: [])
        map["]"]  = HIDKeyMapping(keycode: 0x30, modifiers: [])
        map["\\"] = HIDKeyMapping(keycode: 0x31, modifiers: [])
        map[";"]  = HIDKeyMapping(keycode: 0x33, modifiers: [])
        map["'"]  = HIDKeyMapping(keycode: 0x34, modifiers: [])
        map["`"]  = HIDKeyMapping(keycode: 0x35, modifiers: [])
        map[","]  = HIDKeyMapping(keycode: 0x36, modifiers: [])
        map["."]  = HIDKeyMapping(keycode: 0x37, modifiers: [])
        map["/"]  = HIDKeyMapping(keycode: 0x38, modifiers: [])

        // Punctuation (shifted)
        map["_"]  = HIDKeyMapping(keycode: 0x2D, modifiers: .leftShift)
        map["+"]  = HIDKeyMapping(keycode: 0x2E, modifiers: .leftShift)
        map["{"]  = HIDKeyMapping(keycode: 0x2F, modifiers: .leftShift)
        map["}"]  = HIDKeyMapping(keycode: 0x30, modifiers: .leftShift)
        map["|"]  = HIDKeyMapping(keycode: 0x31, modifiers: .leftShift)
        map[":"]  = HIDKeyMapping(keycode: 0x33, modifiers: .leftShift)
        map["\""] = HIDKeyMapping(keycode: 0x34, modifiers: .leftShift)
        map["~"]  = HIDKeyMapping(keycode: 0x35, modifiers: .leftShift)
        map["<"]  = HIDKeyMapping(keycode: 0x36, modifiers: .leftShift)
        map[">"]  = HIDKeyMapping(keycode: 0x37, modifiers: .leftShift)
        map["?"]  = HIDKeyMapping(keycode: 0x38, modifiers: .leftShift)

        return map
    }()
}

/// Log to stderr.
private func logHelper(_ message: String) {
    FileHandle.standardError.write(Data("[CommandServer] \(message)\n".utf8))
}
