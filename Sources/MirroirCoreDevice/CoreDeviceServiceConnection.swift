// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: libxpc connection to the Mac's com.apple.CoreDevice.CoreDeviceService Mach service.
// ABOUTME: Sends one request dictionary and waits for its reply with a deadline instead of blocking forever.

import Foundation
import XPC

/// The Mach-service connection to CoreDeviceService, the daemon behind
/// `devicectl` and Xcode's device support.
public final class CoreDeviceServiceConnection: CoreDeviceServiceMessaging, @unchecked Sendable {
    /// The Mach service CoreDeviceService listens on.
    public static let machServiceName = "com.apple.CoreDevice.CoreDeviceService"

    private let queue = DispatchQueue(label: "mirroir.coredevice.coredeviceservice")
    private let connection: xpc_connection_t

    /// Connects lazily: libxpc looks the service up on the first message.
    public init() {
        connection = xpc_connection_create_mach_service(Self.machServiceName, queue, 0)
        // Replies travel through each message's own handler; connection-level
        // events (interruption, invalidation) surface there as XPC errors too.
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
    }

    deinit {
        xpc_connection_cancel(connection)
    }

    /// Sends `message` and waits up to `timeout` for the reply. A reply that
    /// arrives after the deadline is dropped by libxpc with its handler; any
    /// descriptor it carries is released with it, since only an explicit
    /// `xpc_dictionary_dup_fd` takes ownership.
    public func sendMessage(_ message: xpc_object_t, timeout: TimeInterval) throws -> xpc_object_t {
        let done = DispatchSemaphore(value: 0)
        let reply = ResultBox<xpc_object_t>()
        xpc_connection_send_message_with_reply(connection, message, queue) { object in
            reply.set(.success(object))
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, case .success(let object)? = reply.value else {
            throw CoreDeviceServiceSocketError.timedOut(seconds: timeout)
        }
        return object
    }
}
