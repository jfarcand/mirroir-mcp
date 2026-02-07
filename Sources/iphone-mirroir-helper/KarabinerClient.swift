// ABOUTME: Karabiner DriverKit virtual HID device client implementing the wire protocol.
// ABOUTME: Communicates with vhidd_server via Unix datagram sockets to send keyboard/pointing reports.

import Darwin
import Foundation

// MARK: - Protocol Constants

/// Karabiner vhidd client protocol version (matches client_protocol_version.hpp).
private let protocolVersion: UInt16 = 5

/// Request types sent to the vhidd server (matches request.hpp).
private enum KarabinerRequest: UInt8 {
    case none = 0
    case virtualHidKeyboardInitialize = 1
    case virtualHidKeyboardTerminate = 2
    case virtualHidKeyboardReset = 3
    case virtualHidPointingInitialize = 4
    case virtualHidPointingTerminate = 5
    case virtualHidPointingReset = 6
    case postKeyboardInputReport = 7
    case postConsumerInputReport = 8
    case postAppleVendorKeyboardInputReport = 9
    case postAppleVendorTopCaseInputReport = 10
    case postGenericDesktopInputReport = 11
    case postPointingInputReport = 12
}

/// Response types received from the vhidd server (matches response.hpp).
private enum KarabinerResponse: UInt8 {
    case none = 0
    case driverActivated = 1
    case driverConnected = 2
    case driverVersionMismatched = 3
    case virtualHidKeyboardReady = 4
    case virtualHidPointingReady = 5
}

// MARK: - Packed Report Structures

/// Keyboard initialization parameters (12 bytes, packed).
/// Matches virtual_hid_keyboard_parameters in parameters.hpp.
private struct KeyboardParameters {
    var vendorID: UInt32 = 0x16c0
    var productID: UInt32 = 0x27db
    var countryCode: UInt32 = 0

    func toBytes() -> [UInt8] {
        var copy = self
        return withUnsafeBytes(of: &copy) { Array($0) }
    }
}

/// Pointing device input report (8 bytes, packed).
/// Matches pointing_input in pointing_input.hpp.
struct PointingInput {
    var buttons: UInt32 = 0
    var x: Int8 = 0
    var y: Int8 = 0
    var verticalWheel: Int8 = 0
    var horizontalWheel: Int8 = 0

    func toBytes() -> [UInt8] {
        var copy = self
        return withUnsafeBytes(of: &copy) { Array($0) }
    }
}

/// Keyboard input report (67 bytes, packed).
/// Matches keyboard_input in keyboard_input.hpp.
struct KeyboardInput {
    var reportID: UInt8 = 1
    var modifiers: UInt8 = 0
    var reserved: UInt8 = 0
    var keys: (
        UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
        UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
        UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
        UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    mutating func insertKey(_ keyCode: UInt16) {
        withUnsafeMutableBytes(of: &keys) { buf in
            let keysPtr = buf.bindMemory(to: UInt16.self)
            // Find first empty slot
            for i in 0..<32 {
                if keysPtr[i] == 0 {
                    keysPtr[i] = keyCode
                    return
                }
            }
        }
    }

    mutating func clearKeys() {
        keys = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    func toBytes() -> [UInt8] {
        var copy = self
        return withUnsafeBytes(of: &copy) { Array($0) }
    }
}

/// Keyboard modifier flags matching the Karabiner modifier bitmask.
struct KeyboardModifier: OptionSet {
    let rawValue: UInt8

    static let leftControl  = KeyboardModifier(rawValue: 0x01)
    static let leftShift    = KeyboardModifier(rawValue: 0x02)
    static let leftOption   = KeyboardModifier(rawValue: 0x04)
    static let leftCommand  = KeyboardModifier(rawValue: 0x08)
    static let rightControl = KeyboardModifier(rawValue: 0x10)
    static let rightShift   = KeyboardModifier(rawValue: 0x20)
    static let rightOption  = KeyboardModifier(rawValue: 0x40)
    static let rightCommand = KeyboardModifier(rawValue: 0x80)
}

// MARK: - Karabiner Client

/// Communicates with the Karabiner DriverKit virtual HID daemon over Unix datagram sockets.
/// Manages device initialization, heartbeat, and HID report submission.
///
/// The protocol uses raw packed structs over Unix DGRAM sockets:
/// - Header: ['c', 'p', version(LE u16), request(u8)]
/// - Payload: packed C struct appended directly after header
final class KarabinerClient {
    private(set) var isKeyboardReady = false
    private(set) var isPointingReady = false
    private(set) var isConnected = false

    private var socketFd: Int32 = -1
    private var serverAddress: sockaddr_un?
    private var clientSocketPath: String?
    private var responseSocketFd: Int32 = -1
    private var responseSocketPath: String?

    private let serverSocketDir = "/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server"
    private let clientSocketDir = "/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_client"
    private let responseSocketDir = "/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_response"

    /// Interval between server liveness checks.
    private let serverCheckIntervalSec: TimeInterval = 3.0
    private var lastServerCheck = Date.distantPast
    private var monitorTimer: DispatchSourceTimer?

    deinit {
        shutdown()
    }

    // MARK: - Connection Management

    /// Initialize the connection to the Karabiner vhidd daemon.
    /// Discovers the server socket, creates client/response sockets, and
    /// initializes both keyboard and pointing virtual devices.
    func initialize() throws {
        // Discover server socket
        guard let serverPath = discoverServerSocket() else {
            throw KarabinerError.noServerSocket
        }
        log("Found server socket: \(serverPath)")

        // Create client datagram socket
        try createClientSocket()

        // Create response socket for receiving device-ready notifications
        try createResponseSocket()

        // Store server address for sendto()
        serverAddress = makeUnixAddress(path: serverPath)

        isConnected = true

        // Initialize virtual devices
        try initializeKeyboard()
        try initializePointing()

        // Wait for devices to become ready
        try waitForDevicesReady(timeoutSec: 5.0)

        // Start periodic server monitoring
        startServerMonitor()

        log("Karabiner client initialized (keyboard=\(isKeyboardReady), pointing=\(isPointingReady))")
    }

    /// Cleanly shut down: terminate virtual devices, close sockets, remove socket files.
    func shutdown() {
        monitorTimer?.cancel()
        monitorTimer = nil

        if isConnected {
            // Terminate virtual devices
            sendRequest(.virtualHidKeyboardTerminate)
            sendRequest(.virtualHidPointingTerminate)
        }

        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
        }
        if responseSocketFd >= 0 {
            Darwin.close(responseSocketFd)
            responseSocketFd = -1
        }

        // Clean up socket files
        if let path = clientSocketPath {
            unlink(path)
            clientSocketPath = nil
        }
        if let path = responseSocketPath {
            unlink(path)
            responseSocketPath = nil
        }

        isKeyboardReady = false
        isPointingReady = false
        isConnected = false
    }

    // MARK: - HID Report Submission

    /// Send a pointing device report (mouse movement, button clicks, scroll).
    func postPointingReport(_ report: PointingInput) {
        sendRequest(.postPointingInputReport, payload: report.toBytes())
    }

    /// Send a keyboard input report.
    func postKeyboardReport(_ report: KeyboardInput) {
        sendRequest(.postKeyboardInputReport, payload: report.toBytes())
    }

    /// Click a mouse button (down then up).
    /// - Parameter button: Button number (1=left, 2=right, 3=middle).
    func click(button: UInt32 = 1) {
        let buttonMask = UInt32(1) << (button - 1)
        var down = PointingInput()
        down.buttons = buttonMask
        postPointingReport(down)

        usleep(80_000) // 80ms hold

        var up = PointingInput()
        up.buttons = 0
        postPointingReport(up)
    }

    /// Release all mouse buttons.
    func releaseButtons() {
        var report = PointingInput()
        report.buttons = 0
        postPointingReport(report)
    }

    /// Move the mouse by a relative amount.
    func moveMouse(dx: Int8, dy: Int8) {
        var report = PointingInput()
        report.x = dx
        report.y = dy
        postPointingReport(report)
    }

    /// Press and release a single key with optional modifiers.
    func typeKey(keycode: UInt16, modifiers: KeyboardModifier = []) {
        // Key down
        var downReport = KeyboardInput()
        downReport.modifiers = modifiers.rawValue
        downReport.insertKey(keycode)
        postKeyboardReport(downReport)

        usleep(20_000) // 20ms hold

        // Key up (empty report releases all keys)
        let upReport = KeyboardInput()
        postKeyboardReport(upReport)
    }

    // MARK: - Private: Socket Management

    private func discoverServerSocket() -> String? {
        let pattern = serverSocketDir + "/*.sock"
        var gt = glob_t()
        defer { globfree(&gt) }

        guard glob(pattern, 0, nil, &gt) == 0 else { return nil }

        // Use the most recently created socket (last one alphabetically since names are timestamps)
        var latestPath: String?
        for i in 0..<Int(gt.gl_pathc) {
            if let cPath = gt.gl_pathv[i] {
                let path = String(cString: cPath)
                if latestPath == nil || path > latestPath! {
                    latestPath = path
                }
            }
        }
        return latestPath
    }

    private func createClientSocket() throws {
        socketFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketFd >= 0 else {
            throw KarabinerError.socketCreationFailed(errno: errno)
        }

        // Bind to a unique path in the client directory
        let timestamp = DispatchTime.now().uptimeNanoseconds
        let path = clientSocketDir + "/\(String(timestamp, radix: 16)).sock"

        var addr = makeUnixAddress(path: path)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFd)
            socketFd = -1
            throw KarabinerError.bindFailed(errno: errno, path: path)
        }

        clientSocketPath = path
        log("Client socket bound: \(path)")
    }

    private func createResponseSocket() throws {
        responseSocketFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard responseSocketFd >= 0 else {
            throw KarabinerError.socketCreationFailed(errno: errno)
        }

        let timestamp = DispatchTime.now().uptimeNanoseconds + 1
        let path = responseSocketDir + "/\(String(timestamp, radix: 16)).sock"

        var addr = makeUnixAddress(path: path)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(responseSocketFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(responseSocketFd)
            responseSocketFd = -1
            throw KarabinerError.bindFailed(errno: errno, path: path)
        }

        responseSocketPath = path

        // Set receive timeout for polling responses
        var tv = timeval(tv_sec: 0, tv_usec: 100_000) // 100ms
        setsockopt(responseSocketFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        log("Response socket bound: \(path)")
    }

    // MARK: - Private: Device Initialization

    private func initializeKeyboard() throws {
        let params = KeyboardParameters()
        sendRequest(.virtualHidKeyboardInitialize, payload: params.toBytes())
    }

    private func initializePointing() throws {
        sendRequest(.virtualHidPointingInitialize)
    }

    /// Poll the response socket until both devices report ready or timeout.
    private func waitForDevicesReady(timeoutSec: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeoutSec)
        var buf = [UInt8](repeating: 0, count: 1024)

        while Date() < deadline {
            let bytesRead = recv(responseSocketFd, &buf, buf.count, 0)
            if bytesRead >= 5 {
                // Parse response header: ['c', 'p', version_le16, response_type, ...]
                guard buf[0] == 0x63, buf[1] == 0x70 else { continue }
                let responseType = buf[4]

                if responseType == KarabinerResponse.virtualHidKeyboardReady.rawValue, bytesRead >= 6 {
                    isKeyboardReady = buf[5] != 0
                    log("Keyboard ready: \(isKeyboardReady)")
                } else if responseType == KarabinerResponse.virtualHidPointingReady.rawValue, bytesRead >= 6 {
                    isPointingReady = buf[5] != 0
                    log("Pointing ready: \(isPointingReady)")
                }

                if isKeyboardReady && isPointingReady { return }
            }

            // recv timed out, re-send init requests to prompt responses
            if !isKeyboardReady {
                let params = KeyboardParameters()
                sendRequest(.virtualHidKeyboardInitialize, payload: params.toBytes())
            }
            if !isPointingReady {
                sendRequest(.virtualHidPointingInitialize)
            }
        }

        // Partial success is acceptable — some operations may still work
        if !isKeyboardReady && !isPointingReady {
            throw KarabinerError.devicesNotReady
        }
    }

    // MARK: - Private: Message Framing

    /// Build and send a Karabiner protocol message.
    /// Frame: ['c'(0x63), 'p'(0x70), version(LE u16), request(u8), ...payload]
    @discardableResult
    private func sendRequest(_ request: KarabinerRequest, payload: [UInt8] = []) -> Bool {
        guard socketFd >= 0, var addr = serverAddress else { return false }

        var message = [UInt8]()
        message.reserveCapacity(5 + payload.count)

        // Header
        message.append(0x63) // 'c'
        message.append(0x70) // 'p'

        // Protocol version (little-endian uint16)
        var version = protocolVersion
        withUnsafeBytes(of: &version) { message.append(contentsOf: $0) }

        // Request type
        message.append(request.rawValue)

        // Payload
        message.append(contentsOf: payload)

        let sent = message.withUnsafeBufferPointer { buf in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(socketFd, buf.baseAddress, buf.count, 0, sockPtr,
                           socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }

        return sent == message.count
    }

    // MARK: - Private: Server Monitoring

    /// Periodically check that the server socket still exists (daemon hasn't restarted).
    private func startServerMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + serverCheckIntervalSec,
                       repeating: serverCheckIntervalSec)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.discoverServerSocket() == nil {
                log("Server socket disappeared — daemon may have restarted")
                self.isConnected = false
                self.isKeyboardReady = false
                self.isPointingReady = false
            }
        }
        timer.resume()
        monitorTimer = timer
    }

    // MARK: - Private: Helpers

    private func makeUnixAddress(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Copy path bytes into sun_path tuple
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
            for i in 0..<min(pathBytes.count, sunPath.count - 1) {
                sunPath[i] = pathBytes[i]
            }
            // Null-terminate
            sunPath[min(pathBytes.count, sunPath.count - 1)] = 0
        }
        return addr
    }
}

// MARK: - Errors

enum KarabinerError: Error, CustomStringConvertible {
    case noServerSocket
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32, path: String)
    case devicesNotReady

    var description: String {
        switch self {
        case .noServerSocket:
            return "No Karabiner vhidd server socket found. Is Karabiner-Elements running with DriverKit activated?"
        case .socketCreationFailed(let e):
            return "Failed to create Unix socket: \(String(cString: strerror(e)))"
        case .bindFailed(let e, let path):
            return "Failed to bind socket at \(path): \(String(cString: strerror(e)))"
        case .devicesNotReady:
            return "Virtual HID devices did not become ready within timeout"
        }
    }
}

// MARK: - Logging

/// Log to stderr (stdout is reserved for IPC in both MCP server and helper).
private func log(_ message: String) {
    FileHandle.standardError.write(Data("[KarabinerClient] \(message)\n".utf8))
}
