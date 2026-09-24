// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Holds a device's CoreDevice tunnel open with a resident `devicectl ... notification observe` child.
// ABOUTME: Starts it, waits for tunnelState connected, and terminates it on stop, deinit or a failed start.

import Foundation

/// Keeps the CoreDevice tunnel of one device leased to this client.
///
/// CoreDeviceService grants service sockets only to a client holding a
/// connection to the device (otherwise: CoreDeviceError 1011), and the tunnel
/// lapses about ten seconds after the last `devicectl` action. A long-running
/// `devicectl device notification observe` holds that connection for as long
/// as it runs, so the lease is that child process. It runs until `stop()`,
/// deinit, or its own session timeout, whichever comes first.
public final class CoreDeviceTunnelLease: @unchecked Sendable {
    /// How long a lease may be held before devicectl ends it on its own. The
    /// bound also caps how long a child outlives a crashed parent.
    public static let defaultSessionTimeout: TimeInterval = 3600
    /// Bound on the tunnel reaching `connected` after the child starts.
    public static let defaultConnectTimeout: TimeInterval = 30
    /// Pause between tunnel-state polls while starting.
    public static let pollInterval: TimeInterval = 0.5
    /// Time a terminated child gets to exit before it is killed.
    public static let defaultTerminationGrace: TimeInterval = 3
    /// The Darwin notification the child observes. Nothing posts it; observing
    /// it is only a way to keep a devicectl session open.
    public static let leaseNotificationName = "com.mirroir.coredevice.lease"
    /// Slack between devicectl's session timeout and its overall command
    /// timeout, which devicectl requires to be the larger of the two.
    static let commandTimeoutMargin: TimeInterval = 60
    static let exitPollInterval: TimeInterval = 0.05

    /// The child process a lease runs: an executable and its arguments, given
    /// the path the child should write its JSON output to.
    public struct KeepAliveCommand: Sendable {
        public let executableURL: URL
        public let arguments: @Sendable (_ jsonOutputPath: String) -> [String]

        public init(executableURL: URL, arguments: @escaping @Sendable (_ jsonOutputPath: String) -> [String]) {
            self.executableURL = executableURL
            self.arguments = arguments
        }

        /// `xcrun devicectl device notification observe` on `device`.
        public static func devicectlObserve(device: String,
                                            sessionTimeout: TimeInterval = CoreDeviceTunnelLease.defaultSessionTimeout)
            -> KeepAliveCommand {
            let session = Int(sessionTimeout.rounded(.up))
            let command = Int((sessionTimeout + CoreDeviceTunnelLease.commandTimeoutMargin).rounded(.up))
            return KeepAliveCommand(executableURL: URL(fileURLWithPath: DevicectlDeviceList.xcrunPath)) { jsonPath in
                ["devicectl", "device", "notification", "observe", "--device", device,
                 "--name", CoreDeviceTunnelLease.leaseNotificationName,
                 "--session-timeout", String(session), "--timeout", String(command),
                 "--quiet", "--json-output", jsonPath]
            }
        }
    }

    /// The CoreDevice identifier (or UDID, or name) of the leased device.
    public let device: String
    private let keepAlive: KeepAliveCommand
    private let tunnelStates: TunnelStateReading
    private let terminationGrace: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var jsonOutput: URL?

    /// - Parameters:
    ///   - device: CoreDevice identifier, UDID or name, as devicectl accepts it.
    ///   - keepAlive: the child to run; `devicectl ... notification observe` by default.
    ///   - tunnelStates: where the tunnel state is read; `devicectl list devices` by default.
    ///   - terminationGrace: how long a terminated child may take to exit before it is killed.
    public init(device: String, keepAlive: KeepAliveCommand? = nil,
                tunnelStates: TunnelStateReading = DevicectlDeviceList(),
                terminationGrace: TimeInterval = CoreDeviceTunnelLease.defaultTerminationGrace) {
        self.device = device
        self.keepAlive = keepAlive ?? .devicectlObserve(device: device)
        self.tunnelStates = tunnelStates
        self.terminationGrace = terminationGrace
    }

    deinit {
        stop()
    }

    /// Whether the keep-alive child is running.
    public var isHeld: Bool {
        lock.withLock { process?.isRunning ?? false }
    }

    /// The keep-alive child's process id while it runs.
    public var keepAliveProcessIdentifier: Int32? {
        lock.withLock { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }
    }

    /// Starts the keep-alive child and waits until the device reports its
    /// tunnel `connected`. Returns at once when the lease is already held. On
    /// any failure the child is terminated before the error propagates.
    public func start(timeout: TimeInterval = CoreDeviceTunnelLease.defaultConnectTimeout) throws {
        if isHeld { return }
        stop()
        let child = try launch()
        let deadline = Date().addingTimeInterval(timeout)
        var lastState: String?
        do {
            while true {
                guard child.isRunning else { throw exitError(of: child) }
                lastState = try tunnelStates.tunnelState(ofDevice: device)
                if lastState == DevicectlDeviceList.connectedState {
                    guard child.isRunning else { throw exitError(of: child) }
                    return
                }
                guard Date() < deadline else {
                    throw CoreDeviceTunnelError.tunnelNotConnected(device: device, tunnelState: lastState)
                }
                Thread.sleep(forTimeInterval: Self.pollInterval)
            }
        } catch {
            stop()
            throw error
        }
    }

    /// Terminates the keep-alive child (killing it after the grace period) and
    /// waits for it to exit. Idempotent.
    public func stop() {
        let (child, output): (Process?, URL?) = lock.withLock {
            defer {
                process = nil
                jsonOutput = nil
            }
            return (process, jsonOutput)
        }
        if let child, child.isRunning {
            child.terminate()
            let deadline = Date().addingTimeInterval(terminationGrace)
            while child.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: Self.exitPollInterval)
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        if let output { try? FileManager.default.removeItem(at: output) }
    }

    // MARK: - Internals

    private func launch() throws -> Process {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirroir-lease-\(UUID().uuidString).json")
        let child = Process()
        child.executableURL = keepAlive.executableURL
        child.arguments = keepAlive.arguments(output.path)
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            throw CoreDeviceTunnelError.keepAliveLaunchFailed(reason: "\(error)")
        }
        lock.withLock {
            process = child
            jsonOutput = output
        }
        return child
    }

    /// The error for a child that exited: its status, and the CoreDevice
    /// failure it wrote to its JSON output when it wrote one.
    private func exitError(of child: Process) -> CoreDeviceTunnelError {
        child.waitUntilExit()
        let output = lock.withLock { jsonOutput }
        let failure = output.flatMap { try? Data(contentsOf: $0) }.flatMap(DevicectlDeviceList.failure(in:))
        return .keepAliveExited(status: child.terminationStatus, failure: failure)
    }
}
