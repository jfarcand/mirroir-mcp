// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Blocking ByteTransport over a connected socket file descriptor, such as a CoreDevice service socket.
// ABOUTME: Non-blocking I/O under poll() deadlines; a timeout or close() shuts the socket and wakes pending I/O.

import Foundation

/// A connected stream socket exposed as a blocking `ByteTransport`. The
/// transport owns the descriptor it adopts and closes it exactly once.
///
/// Reads and writes may run concurrently on different threads (HTTP/2 reads
/// while it writes). `close()` from any thread shuts the socket down, which
/// wakes blocked I/O; the descriptor itself is released only once no
/// operation still uses it, so a recycled descriptor number is never touched.
public final class FileDescriptorTransport: ByteTransport, @unchecked Sendable {
    /// Bound on a single read or write. A RemoteXPC reply that has not started
    /// arriving by then will not arrive.
    public static let defaultIOTimeout: TimeInterval = 30
    /// Largest chunk one `read` asks the kernel for.
    public static let readChunkLength = 64 * 1024
    static let millisecondsPerSecond: Double = 1000

    private let descriptor: Int32
    private let ioTimeout: TimeInterval
    private let lock = NSLock()
    private var closed = false
    private var released = false
    private var activeOperations = 0

    /// Adopts `descriptor`, a connected stream socket, and makes it
    /// non-blocking. The descriptor is closed when adoption fails.
    public init(adopting descriptor: Int32, ioTimeout: TimeInterval = FileDescriptorTransport.defaultIOTimeout) throws {
        guard descriptor >= 0 else { throw TransportError.invalidFileDescriptor(descriptor) }
        self.descriptor = descriptor
        self.ioTimeout = ioTimeout
        do {
            try configure()
        } catch {
            released = true
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        if !released { Darwin.close(descriptor) }
    }

    /// No SIGPIPE on a write to a peer that went away (the write fails with
    /// EPIPE instead), and non-blocking I/O so every wait goes through poll().
    private func configure() throws {
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw Self.systemFailure("configure")
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Self.systemFailure("configure")
        }
    }

    /// Writes every byte, looping over partial writes.
    public func write(_ data: Data) throws {
        try withOperation {
            let deadline = Date().addingTimeInterval(ioTimeout)
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EAGAIN || errno == EINTR {
                        try waitUntilReady(for: Int16(POLLOUT), deadline: deadline, operation: "write")
                    } else {
                        throw Self.systemFailure("write")
                    }
                }
            }
        }
    }

    /// Returns between one and `maximumLength` bytes (at most
    /// `readChunkLength`), whatever the peer has sent so far.
    public func read(maximumLength: Int) throws -> Data {
        try withOperation {
            let deadline = Date().addingTimeInterval(ioTimeout)
            var buffer = [UInt8](repeating: 0, count: max(1, min(maximumLength, Self.readChunkLength)))
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(descriptor, raw.baseAddress, raw.count)
                }
                if count > 0 { return Data(buffer[0..<count]) }
                if count == 0 { throw TransportError.closed }
                guard errno == EAGAIN || errno == EINTR else { throw Self.systemFailure("read") }
                try waitUntilReady(for: Int16(POLLIN), deadline: deadline, operation: "read")
            }
        }
    }

    /// Shuts the socket down and releases the descriptor once no read or
    /// write still uses it. Idempotent; a blocked read returns `closed`.
    public func close() {
        let releaseNow: Bool? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            guard activeOperations == 0 else { return false }
            released = true
            return true
        }
        guard let releaseNow else { return }
        shutdown(descriptor, SHUT_RDWR)
        if releaseNow { Darwin.close(descriptor) }
    }

    // MARK: - Internals

    private func withOperation<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard !closed else { throw TransportError.closed }
            activeOperations += 1
        }
        defer { endOperation() }
        return try body()
    }

    private func endOperation() {
        let releaseNow: Bool = lock.withLock {
            activeOperations -= 1
            guard closed, activeOperations == 0, !released else { return false }
            released = true
            return true
        }
        if releaseNow { Darwin.close(descriptor) }
    }

    /// Waits in poll() until the socket is ready for `events` or `deadline`
    /// passes. A timeout closes the transport: whatever arrives later would
    /// land mid-frame, so the stream cannot be resumed.
    private func waitUntilReady(for events: Int16, deadline: Date, operation: String) throws {
        while true {
            if lock.withLock({ closed }) { throw TransportError.closed }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                close()
                throw TransportError.timedOut(operation: operation)
            }
            var request = pollfd(fd: descriptor, events: events, revents: 0)
            let milliseconds = Int32(min(remaining * Self.millisecondsPerSecond, Double(Int32.max)).rounded(.up))
            let result = poll(&request, 1, milliseconds)
            if result > 0 {
                if request.revents & Int16(POLLNVAL) != 0 { throw TransportError.closed }
                return
            }
            if result < 0, errno != EINTR { throw Self.systemFailure("poll") }
        }
    }

    private static func systemFailure(_ operation: String) -> TransportError {
        TransportError.failed(operation: operation, reason: String(cString: strerror(errno)))
    }
}
