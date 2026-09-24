// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: System-boundary protocols of the CoreDevice stack: byte transport, HID sink, CoreDeviceService, tunnel state.
// ABOUTME: Real implementations use a socket fd, RemoteXPC, libxpc and devicectl; tests substitute fakes.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation
import XPC

/// A blocking, ordered byte stream: a connected service socket to the device
/// in production, an in-memory buffer in tests. HTTP/2 framing sits on top.
public protocol ByteTransport: AnyObject {
    /// Writes every byte of `data`, blocking until the transport accepted them.
    func write(_ data: Data) throws
    /// Blocks until at least one byte is available and returns up to
    /// `maximumLength` bytes. Throws `TransportError.closed` at end of stream.
    func read(maximumLength: Int) throws -> Data
    /// Closes the transport. Idempotent; unblocks a pending read.
    func close()
}

extension ByteTransport {
    /// Reads exactly `count` bytes, looping over short reads.
    public func readExactly(_ count: Int) throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            buffer.append(try read(maximumLength: count - buffer.count))
        }
        return buffer
    }
}

/// Delivers one HID report to a service on the device. The universal HID
/// service in production; a recording fake in tests.
public protocol HIDReportSending: AnyObject {
    /// Sends `report` to the HID service `serviceID`. The device never answers,
    /// so success means the report was written, not that anything moved.
    func sendReport(_ report: Data, serviceID: UInt64) throws
    /// Releases the underlying connection.
    func close()
}

/// Exchanges one libxpc message with the Mac's CoreDeviceService. The Mach
/// service connection in production; a fake that inspects the request and
/// returns canned replies in tests.
public protocol CoreDeviceServiceMessaging: AnyObject {
    /// Sends `message` and blocks until its reply or `timeout`. The reply is a
    /// dictionary, or an XPC error object when the connection itself failed.
    /// Throws `CoreDeviceServiceSocketError.timedOut` past the deadline.
    func sendMessage(_ message: xpc_object_t, timeout: TimeInterval) throws -> xpc_object_t
}

/// Reports the CoreDevice tunnel state of a device (`connected`,
/// `connecting`, `unavailable`, ...). `devicectl list devices` in production.
public protocol TunnelStateReading: AnyObject {
    /// The tunnel state of the device whose CoreDevice identifier, UDID or name
    /// is `device`; `nil` when the device entry carries none.
    func tunnelState(ofDevice device: String) throws -> String?
}
