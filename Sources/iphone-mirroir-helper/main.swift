// ABOUTME: Entry point for the privileged Karabiner helper daemon.
// ABOUTME: Initializes the Karabiner virtual HID client and starts the Unix socket command server.

import Darwin
import Dispatch
import Foundation

/// Log to stderr (consistent with KarabinerClient and CommandServer).
private func log(_ message: String) {
    FileHandle.standardError.write(Data("[Helper] \(message)\n".utf8))
}

// MARK: - Main

log("iphone-mirroir-helper starting (pid: \(ProcessInfo.processInfo.processIdentifier))")

// Verify running as root
guard getuid() == 0 else {
    log("ERROR: Helper must run as root (current uid: \(getuid())). Use sudo or install as LaunchDaemon.")
    exit(1)
}

// Initialize Karabiner virtual HID client.
// If Karabiner is unavailable (no DriverKit extension, CI environment, etc.),
// the helper starts in degraded mode: status queries work, input commands
// return clear errors about Karabiner not being ready.
let karabiner = KarabinerClient()
do {
    try karabiner.initialize()
    log("Karabiner client connected (keyboard=\(karabiner.isKeyboardReady), pointing=\(karabiner.isPointingReady))")
} catch {
    log("WARNING: Karabiner not available: \(error)")
    log("Starting in degraded mode — status queries work, input commands will return errors.")
    log("To enable full functionality, install Karabiner-Elements and activate the DriverKit extension.")
}

// Start the command server (blocks until stopped)
let server = CommandServer(karabiner: karabiner)

// Handle graceful shutdown via GCD signal sources.
// DispatchSource captures server/karabiner in its closure, eliminating the
// need for nonisolated(unsafe) references across actor boundaries.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .utility))

let shutdownHandler: () -> Void = {
    log("Received termination signal, shutting down...")
    server.stop()
    karabiner.shutdown()
    log("Shutdown complete")
    exit(0)
}

sigtermSource.setEventHandler(handler: shutdownHandler)
sigintSource.setEventHandler(handler: shutdownHandler)
sigtermSource.resume()
sigintSource.resume()

do {
    try server.start()
} catch {
    log("ERROR: Command server failed: \(error)")
    karabiner.shutdown()
    exit(1)
}
