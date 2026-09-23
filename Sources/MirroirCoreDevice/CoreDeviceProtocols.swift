// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: System-boundary protocols of the CoreDevice stack: the byte transport and the HID report sink.
// ABOUTME: Real implementations use Network.framework and RemoteXPC; tests substitute in-memory fakes.

import Foundation

/// A blocking, ordered byte stream: a TCP connection to the device in
/// production, an in-memory buffer in tests. HTTP/2 framing sits on top.
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
