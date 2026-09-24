// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The HTTP/2 client connection RemoteXPC runs on: preface, settings exchange, and the two XPC streams.
// ABOUTME: Faithful port of go-ios ios/http/http.go, with DATA writes split at the peer's frame-size limit.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation

/// The HTTP/2 streams RemoteXPC multiplexes.
public enum RemoteXPCStream: UInt32, Sendable {
    /// Connection-level frames (settings, window updates).
    case connection = 0
    /// Requests from the client and their replies ("ClientServer" in go-ios).
    case clientServer = 1
    /// Messages the server initiates ("ServerClient" in go-ios).
    case serverClient = 3
}

/// An HTTP/2 connection as RemoteXPC uses it: two long-lived bidirectional
/// streams (1 and 3), no header compression (header blocks are empty), and the
/// flow-control windows opened wide once at start-up.
///
/// Reads and writes are serialised by separate locks, so a read blocked waiting
/// for the device never holds up a write (a HID session only ever writes).
public final class HTTP2Connection {
    /// SETTINGS_MAX_CONCURRENT_STREAMS the client advertises (go-ios value).
    public static let advertisedMaxConcurrentStreams: UInt32 = 100
    /// SETTINGS_INITIAL_WINDOW_SIZE the client advertises: 1 MiB (go-ios value).
    public static let advertisedInitialWindowSize: UInt32 = 1_048_576
    /// Connection window increment sent after the settings: 983041 bytes,
    /// raising the 65535-byte default connection window to 1 MiB + 1 (go-ios value).
    public static let connectionWindowIncrement: UInt32 = 983_041

    private let transport: ByteTransport
    private let framer: HTTP2Framer
    /// Guards frame writes, `openedStreams` and `peerMaxFrameSize`.
    private let writeLock = NSLock()
    /// Guards frame reads and the per-stream receive buffers.
    private let readLock = NSLock()
    private var buffers: [RemoteXPCStream: Data] = [.clientServer: Data(), .serverClient: Data()]
    private var openedStreams: Set<RemoteXPCStream> = []
    private var peerMaxFrameSize = HTTP2Framer.defaultMaxFrameSize

    /// Performs the client side of connection set-up over `transport`:
    /// preface, SETTINGS, WINDOW_UPDATE, then reads the server's first frame and
    /// acknowledges it when it is SETTINGS.
    public init(transport: ByteTransport) throws {
        self.transport = transport
        self.framer = HTTP2Framer(transport: transport)
        try framer.writePreface()
        try framer.writeSettings([
            (.maxConcurrentStreams, Self.advertisedMaxConcurrentStreams),
            (.initialWindowSize, Self.advertisedInitialWindowSize),
        ])
        try framer.writeWindowUpdate(
            streamID: RemoteXPCStream.connection.rawValue, increment: Self.connectionWindowIncrement)

        let first = try framer.readFrame()
        guard first.type == .settings else { return }
        applyPeerSettings(first)
        try framer.writeSettingsAck()
    }

    /// go-ios feeds the peer's SETTINGS_INITIAL_WINDOW_SIZE to
    /// `SetMaxReadFrameSize`; this keeps that behaviour, clamped to what a
    /// frame header can express, and also honours SETTINGS_MAX_FRAME_SIZE for
    /// the frames this side writes.
    private func applyPeerSettings(_ frame: HTTP2Frame) {
        for setting in HTTP2Framer.settings(in: frame) {
            switch HTTP2SettingID(rawValue: setting.id) {
            case .initialWindowSize:
                framer.maxReadFrameSize = min(Int(setting.value), HTTP2Framer.largestFrameLength)
            case .maxFrameSize:
                writeLock.withLock {
                    peerMaxFrameSize = min(Int(setting.value), HTTP2Framer.largestFrameLength)
                }
            default:
                continue
            }
        }
    }

    /// Writes `payload` on `stream`, sending an empty HEADERS frame first the
    /// first time the stream is written. Payloads larger than the peer's frame
    /// size are split across DATA frames; go-ios writes a single frame, which is
    /// equivalent for every payload under the 16 KiB default.
    public func write(_ payload: Data, on stream: RemoteXPCStream) throws {
        guard stream != .connection else { throw HTTP2Error.unsupportedStream(stream.rawValue) }
        writeLock.lock()
        defer { writeLock.unlock() }
        if !openedStreams.contains(stream) {
            try framer.writeHeaders(streamID: stream.rawValue)
            openedStreams.insert(stream)
        }
        var offset = payload.startIndex
        repeat {
            let end = min(offset + peerMaxFrameSize, payload.endIndex)
            try framer.writeData(streamID: stream.rawValue, payload: payload[offset..<end])
            offset = end
        } while offset < payload.endIndex
    }

    /// Reads exactly `count` bytes from `stream`, pulling frames off the wire
    /// (and buffering data for the other stream) until enough has arrived.
    public func read(_ count: Int, from stream: RemoteXPCStream) throws -> Data {
        guard stream != .connection else { throw HTTP2Error.unsupportedStream(stream.rawValue) }
        readLock.lock()
        defer { readLock.unlock() }
        while buffers[stream, default: Data()].count < count {
            try readDataFrame()
        }
        let buffered = buffers[stream, default: Data()]
        let result = buffered.prefix(count)
        buffers[stream] = Data(buffered.dropFirst(count))
        return Data(result)
    }

    /// Reads frames until one DATA frame has been buffered, handling the
    /// control frames go-ios handles and ignoring the rest.
    private func readDataFrame() throws {
        while true {
            let frame = try framer.readFrame()
            switch frame.type {
            case .data:
                guard let stream = RemoteXPCStream(rawValue: frame.streamID), stream != .connection else {
                    throw HTTP2Error.unexpectedStream(frame.streamID)
                }
                buffers[stream, default: Data()].append(try HTTP2Framer.dataPayload(of: frame))
                return
            case .goAway:
                throw HTTP2Error.goAway(
                    lastStreamID: HTTP2Framer.word(in: frame, at: 0) & HTTP2Framer.reservedBitMask,
                    errorCode: HTTP2Framer.word(in: frame, at: HTTP2Framer.streamIDFieldWidth))
            case .settings:
                if !frame.has(flag: HTTP2Flags.ack) {
                    applyPeerSettings(frame)
                    try writeLock.withLock { try framer.writeSettingsAck() }
                }
            case .rstStream:
                throw HTTP2Error.streamReset(streamID: frame.streamID, errorCode: HTTP2Framer.word(in: frame, at: 0))
            default:
                continue
            }
        }
    }

    /// Closes the underlying transport.
    public func close() {
        transport.close()
    }
}
