// ABOUTME: Entry point for the privileged Karabiner helper daemon.
// ABOUTME: Initializes the Karabiner virtual HID client and starts the Unix socket command server.

import Darwin
import Foundation

/// Log to stderr (consistent with KarabinerClient and CommandServer).
private func log(_ message: String) {
    FileHandle.standardError.write(Data("[Helper] \(message)\n".utf8))
}

// MARK: - Signal Handling

/// Atomic flag for cross-thread signal notification.
/// Uses nonisolated(unsafe) because signal handlers run on arbitrary threads
/// and cannot participate in Swift's actor isolation model.
private nonisolated(unsafe) var shouldTerminate = false

private func setupSignalHandlers() {
    let handler: @convention(c) (Int32) -> Void = { _ in
        shouldTerminate = true
    }
    signal(SIGTERM, handler)
    signal(SIGINT, handler)
}

// MARK: - Main

log("iphone-mirroir-helper starting (pid: \(ProcessInfo.processInfo.processIdentifier))")

// Verify running as root
guard getuid() == 0 else {
    log("ERROR: Helper must run as root (current uid: \(getuid())). Use sudo or install as LaunchDaemon.")
    exit(1)
}

setupSignalHandlers()

// Initialize Karabiner virtual HID client
let karabiner = KarabinerClient()
do {
    try karabiner.initialize()
    log("Karabiner client connected (keyboard=\(karabiner.isKeyboardReady), pointing=\(karabiner.isPointingReady))")
} catch {
    log("ERROR: Failed to initialize Karabiner client: \(error)")
    log("Ensure Karabiner-Elements is installed and DriverKit extension is activated.")
    exit(1)
}

// Start the command server (blocks until stopped)
let server = CommandServer(karabiner: karabiner)

// Handle graceful shutdown in a background thread.
// These references cross actor boundaries but are safe because:
// - shouldTerminate is only written from the signal handler (atomic on macOS)
// - server.stop() / karabiner.shutdown() are thread-safe shutdown methods
nonisolated(unsafe) let serverRef = server
nonisolated(unsafe) let karabinerRef = karabiner
DispatchQueue.global(qos: .utility).async {
    while !shouldTerminate {
        Thread.sleep(forTimeInterval: 0.5)
    }
    log("Received termination signal, shutting down...")
    serverRef.stop()
    karabinerRef.shutdown()
    log("Shutdown complete")
    exit(0)
}

do {
    try server.start()
} catch {
    log("ERROR: Command server failed: \(error)")
    karabiner.shutdown()
    exit(1)
}
