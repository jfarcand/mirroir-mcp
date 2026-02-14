// ABOUTME: Karabiner DriverKit virtual HID device client implementing the wire protocol.
// ABOUTME: Communicates with vhidd_server via Unix datagram sockets to send keyboard/pointing reports.

import Darwin
import Foundation
import HelperLib

// MARK: - Protocol Constants

/// Karabiner vhidd client protocol version (uint16_t, matches client_protocol_version.hpp).
private let protocolVersion: UInt16 = 5

/// The local_datagram framing layer prepends a type byte to every datagram.
/// 0 = heartbeat, 1 = user_data (matches send_entry::type in send_entry.hpp).
private let heartbeatTypeByte: UInt8 = 0
private let userDataTypeByte: UInt8 = 1

/// Heartbeat deadline in milliseconds. The server considers the client dead
/// if no heartbeat arrives within this window (matches C++ client default).
private let heartbeatDeadlineMs: UInt32 = 5000

/// Heartbeat interval in seconds (matches C++ local_datagram::client default).
private let heartbeatIntervalSec: TimeInterval = 3.0

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

// MARK: - Karabiner Client

/// Communicates with the Karabiner DriverKit virtual HID daemon over Unix datagram sockets.
/// Manages device initialization, heartbeat, and HID report submission.
///
/// The protocol uses the pqrs::local_datagram framing layer over Unix DGRAM sockets:
/// - Heartbeat: [0x00] [deadline_ms uint32 LE] (5 bytes, sent every 3s)
/// - User data: [0x01] ['c'] ['p'] [version LE uint16] [request uint8] [...payload]
///
/// The client must connect() to the server socket before sending (matching the C++
/// local_datagram::client behavior). Responses arrive on the same client socket from
/// a server-created response socket in the vhidd_response directory.
final class KarabinerClient {
    private(set) var isKeyboardReady = false
    private(set) var isPointingReady = false
    private(set) var isConnected = false

    private var socketFd: Int32 = -1
    private var clientSocketPath: String?

    private let serverSocketDir = "/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server"
    private let clientSocketDir = "/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_client"

    private var heartbeatTimer: DispatchSourceTimer?
    private var monitorTimer: DispatchSourceTimer?

    /// Interval between server liveness checks.
    private let serverCheckIntervalSec: TimeInterval = 3.0

    deinit {
        shutdown()
    }

    // MARK: - Connection Management

    /// Initialize the connection to the Karabiner vhidd daemon.
    /// Discovers the server socket, creates and connects the client socket,
    /// starts heartbeat, and initializes both keyboard and pointing virtual devices.
    func initialize() throws {
        // Discover server socket
        guard let serverPath = discoverServerSocket() else {
            throw KarabinerError.noServerSocket
        }
        log("Found server socket: \(serverPath)")

        // Create client datagram socket and bind to client directory
        try createClientSocket()

        // Connect to server (required by local_datagram protocol).
        // On macOS, connect() on Unix DGRAM sets the default destination for send()
        // but does not filter incoming datagrams (unlike Linux UDP sockets).
        try connectToServer(path: serverPath)

        // Set receive timeout for polling responses
        var tv = timeval(tv_sec: 0, tv_usec: EnvConfig.recvTimeoutUs)
        setsockopt(socketFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        isConnected = true

        // Start heartbeat before sending requests (matches C++ client startup order).
        // The server uses heartbeats to track active clients and manage response sockets.
        sendHeartbeat()
        startHeartbeat()

        // Small delay to let the server process the heartbeat and create our response socket
        usleep(EnvConfig.postHeartbeatSettleUs)

        // Initialize virtual devices
        initializeKeyboard()
        initializePointing()

        // Wait for devices to become ready
        try waitForDevicesReady(timeoutSec: 10.0)

        // Start periodic server monitoring
        startServerMonitor()

        log("Karabiner client initialized (keyboard=\(isKeyboardReady), pointing=\(isPointingReady))")
    }

    /// Cleanly shut down: terminate virtual devices, close sockets, remove socket files.
    func shutdown() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        monitorTimer?.cancel()
        monitorTimer = nil

        if isConnected {
            sendRequest(.virtualHidKeyboardTerminate)
            sendRequest(.virtualHidPointingTerminate)
        }

        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
        }

        if let path = clientSocketPath {
            unlink(path)
            clientSocketPath = nil
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

        usleep(EnvConfig.clickHoldUs)

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
        let downBytes = downReport.toBytes()
        log("typeKey DOWN: keycode=0x\(String(keycode, radix: 16)), mods=0x\(String(modifiers.rawValue, radix: 16)), payload=\(downBytes.count) bytes")
        let downOk = sendRequest(.postKeyboardInputReport, payload: downBytes)
        log("typeKey DOWN send: \(downOk)")

        usleep(EnvConfig.keyHoldUs)

        // Key up (empty report releases all keys)
        let upReport = KeyboardInput()
        let upOk = sendRequest(.postKeyboardInputReport, payload: upReport.toBytes())
        log("typeKey UP send: \(upOk)")
    }

    // MARK: - Private: Socket Management

    private func discoverServerSocket() -> String? {
        let pattern = serverSocketDir + "/*.sock"
        var gt = glob_t()
        defer { globfree(&gt) }

        guard glob(pattern, 0, nil, &gt) == 0 else { return nil }

        // Use the most recently created socket (last one alphabetically since names are hex timestamps)
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

        // Remove stale socket file if it exists
        unlink(path)

        var addr = makeUnixAddress(path: path)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            Darwin.close(socketFd)
            socketFd = -1
            throw KarabinerError.bindFailed(errno: e, path: path)
        }

        clientSocketPath = path
        log("Client socket bound: \(path)")
    }

    /// Connect the DGRAM socket to the server. Required by the local_datagram protocol.
    /// The C++ client always calls connect() before sending. This sets the default
    /// destination for send() and lets the server identify our client socket path.
    private func connectToServer(path: String) throws {
        var addr = makeUnixAddress(path: path)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socketFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let e = errno
            throw KarabinerError.connectFailed(errno: e, path: path)
        }
        log("Connected to server socket: \(path)")
    }

    // MARK: - Private: Heartbeat

    /// Send a heartbeat datagram: [0x00 (type::heartbeat)] [deadline_ms (uint32 LE)].
    /// The deadline tells the server how long to wait before considering this client dead.
    /// Format matches local_datagram::send_entry with type::heartbeat.
    private func sendHeartbeat() {
        guard socketFd >= 0 else { return }

        var message = [UInt8](repeating: 0, count: 5)
        message[0] = heartbeatTypeByte
        var deadline = heartbeatDeadlineMs.littleEndian
        withUnsafeBytes(of: &deadline) { src in
            for i in 0..<4 { message[1 + i] = src[i] }
        }

        let sent = message.withUnsafeBufferPointer { buf in
            Darwin.send(socketFd, buf.baseAddress, buf.count, 0)
        }
        if sent != message.count {
            log("Heartbeat send failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Start periodic heartbeat timer (matches C++ local_datagram::client behavior).
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + heartbeatIntervalSec,
                       repeating: heartbeatIntervalSec)
        timer.setEventHandler { [weak self] in
            self?.sendHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: - Private: Device Initialization

    private func initializeKeyboard() {
        let params = KeyboardParameters()
        sendRequest(.virtualHidKeyboardInitialize, payload: params.toBytes())
    }

    private func initializePointing() {
        sendRequest(.virtualHidPointingInitialize)
    }

    /// Poll the client socket until both devices report ready or timeout.
    /// The server sends responses to our client socket from its response socket.
    ///
    /// Uses a blocking recv() with SO_RCVTIMEO (set during initialize) as the
    /// polling mechanism. Each recv() times out after recvTimeoutUs, at which
    /// point we re-send init requests to prompt the server. This avoids busy-wait
    /// while keeping latency low.
    private func waitForDevicesReady(timeoutSec: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeoutSec)
        var buf = [UInt8](repeating: 0, count: 1024)
        var attempt = 0

        while Date() < deadline {
            let bytesRead = recv(socketFd, &buf, buf.count, 0)
            if bytesRead > 0 {
                let hexBytes = buf[0..<bytesRead].map { String(format: "%02x", $0) }.joined(separator: " ")
                log("Received \(bytesRead) bytes: \(hexBytes)")
                try parseResponse(buf: buf, bytesRead: bytesRead)
                if isKeyboardReady && isPointingReady { return }
            } else if bytesRead < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                log("recv error: \(String(cString: strerror(errno)))")
            }

            attempt += 1
            // Re-send init requests periodically to prompt responses
            if !isKeyboardReady {
                let params = KeyboardParameters()
                let sent = sendRequest(.virtualHidKeyboardInitialize, payload: params.toBytes())
                if attempt <= 5 { log("Sent keyboard init (attempt \(attempt)): \(sent)") }
            }
            if !isPointingReady {
                let sent = sendRequest(.virtualHidPointingInitialize)
                if attempt <= 5 { log("Sent pointing init (attempt \(attempt)): \(sent)") }
            }
        }

        if !isKeyboardReady && !isPointingReady {
            throw KarabinerError.devicesNotReady
        }
    }

    /// Parse a response from the Karabiner vhidd server.
    /// Wire format: [type(u8)] [response_type(u8)] [...payload]
    /// The type byte is the local_datagram framing prefix (0x00=heartbeat, 0x01=user_data).
    private func parseResponse(buf: [UInt8], bytesRead: Int) throws {
        guard bytesRead >= 1 else { return }

        let framingType = buf[0]

        // Heartbeat responses from the server
        if framingType == heartbeatTypeByte {
            log("Received heartbeat from server")
            return
        }

        guard framingType == userDataTypeByte else {
            log("Unexpected framing type: \(framingType)")
            return
        }

        guard bytesRead >= 2 else { return }
        let responseType = buf[1]
        log("Response type: \(responseType)")

        if responseType == KarabinerResponse.driverVersionMismatched.rawValue, bytesRead >= 3 {
            // The value byte indicates whether versions ARE mismatched (1=yes, 0=no).
            // This is a periodic status report, not an error — only throw if truly mismatched.
            let mismatched = buf[2] != 0
            log("Driver version mismatched: \(mismatched)")
            if mismatched {
                throw KarabinerError.driverVersionMismatch
            }
        } else if responseType == KarabinerResponse.virtualHidKeyboardReady.rawValue, bytesRead >= 3 {
            isKeyboardReady = buf[2] != 0
            log("Keyboard ready: \(isKeyboardReady)")
        } else if responseType == KarabinerResponse.virtualHidPointingReady.rawValue, bytesRead >= 3 {
            isPointingReady = buf[2] != 0
            log("Pointing ready: \(isPointingReady)")
        } else if responseType == KarabinerResponse.driverActivated.rawValue, bytesRead >= 3 {
            log("Driver activated: \(buf[2])")
        } else if responseType == KarabinerResponse.driverConnected.rawValue, bytesRead >= 3 {
            log("Driver connected: \(buf[2])")
        }
    }

    // MARK: - Private: Message Framing

    /// Build and send a Karabiner protocol message via the connected socket.
    /// Wire format: [0x01] ['c'(0x63)] ['p'(0x70)] [version(LE u16)] [request(u8)] [...payload]
    /// Uses send() on the connected socket (not sendto()), matching C++ local_datagram::client.
    @discardableResult
    private func sendRequest(_ request: KarabinerRequest, payload: [UInt8] = []) -> Bool {
        guard socketFd >= 0 else { return false }

        var message = [UInt8]()
        message.reserveCapacity(6 + payload.count)

        // local_datagram framing: type byte (1 = user_data)
        message.append(userDataTypeByte)
        // Karabiner header: 'c', 'p', protocol_version (uint16_t LE), request_type (uint8_t)
        message.append(0x63) // 'c'
        message.append(0x70) // 'p'
        var version = protocolVersion.littleEndian
        withUnsafeBytes(of: &version) { message.append(contentsOf: $0) }
        message.append(request.rawValue)

        // Payload
        message.append(contentsOf: payload)

        let sent = message.withUnsafeBufferPointer { buf in
            Darwin.send(socketFd, buf.baseAddress, buf.count, 0)
        }

        if sent != message.count {
            log("Send failed for \(request) (errno \(errno)): \(String(cString: strerror(errno)))")
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
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
            for i in 0..<min(pathBytes.count, sunPath.count - 1) {
                sunPath[i] = pathBytes[i]
            }
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
    case connectFailed(errno: Int32, path: String)
    case devicesNotReady
    case driverVersionMismatch

    var description: String {
        switch self {
        case .noServerSocket:
            return "No Karabiner vhidd server socket found. Is Karabiner-Elements running with DriverKit activated?"
        case .socketCreationFailed(let e):
            return "Failed to create Unix socket: \(String(cString: strerror(e)))"
        case .bindFailed(let e, let path):
            return "Failed to bind socket at \(path): \(String(cString: strerror(e)))"
        case .connectFailed(let e, let path):
            return "Failed to connect to server at \(path): \(String(cString: strerror(e)))"
        case .devicesNotReady:
            return "Virtual HID devices did not become ready within timeout"
        case .driverVersionMismatch:
            return "Karabiner driver version mismatch — reinstall Karabiner-Elements or rebuild the helper"
        }
    }
}

// MARK: - Logging

/// Log to stderr (stdout is reserved for IPC in both MCP server and helper).
private func log(_ message: String) {
    FileHandle.standardError.write(Data("[KarabinerClient] \(message)\n".utf8))
}
