// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Minimal HTTP/2 frame reader and writer (RFC 9113 section 4) over a ByteTransport.
// ABOUTME: Covers exactly the frame types RemoteXPC exchanges, mirroring golang.org/x/net/http2's Framer as go-ios uses it.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation

/// HTTP/2 frame types RemoteXPC exchanges (RFC 9113 section 6).
public enum HTTP2FrameType: UInt8, Sendable {
    case data = 0x0
    case headers = 0x1
    case priority = 0x2
    case rstStream = 0x3
    case settings = 0x4
    case pushPromise = 0x5
    case ping = 0x6
    case goAway = 0x7
    case windowUpdate = 0x8
    case continuation = 0x9
}

/// HTTP/2 frame flag bits used by RemoteXPC.
public enum HTTP2Flags {
    /// SETTINGS acknowledgement.
    public static let ack: UInt8 = 0x1
    /// HEADERS: the header block is complete in this frame.
    public static let endHeaders: UInt8 = 0x4
    /// DATA and HEADERS: the payload is padded.
    public static let padded: UInt8 = 0x8
}

/// HTTP/2 SETTINGS identifiers (RFC 9113 section 6.5.2).
public enum HTTP2SettingID: UInt16, Sendable {
    case headerTableSize = 0x1
    case enablePush = 0x2
    case maxConcurrentStreams = 0x3
    case initialWindowSize = 0x4
    case maxFrameSize = 0x5
    case maxHeaderListSize = 0x6
}

/// One frame as read off, or about to be written to, the wire.
public struct HTTP2Frame: Equatable, Sendable {
    /// Raw type byte, so frames of unknown types can be read and skipped.
    public let rawType: UInt8
    public let flags: UInt8
    public let streamID: UInt32
    public let payload: Data

    public init(type: HTTP2FrameType, flags: UInt8 = 0, streamID: UInt32, payload: Data = Data()) {
        self.init(rawType: type.rawValue, flags: flags, streamID: streamID, payload: payload)
    }

    public init(rawType: UInt8, flags: UInt8, streamID: UInt32, payload: Data) {
        self.rawType = rawType
        self.flags = flags
        self.streamID = streamID
        self.payload = payload
    }

    public var type: HTTP2FrameType? { HTTP2FrameType(rawValue: rawType) }

    public func has(flag: UInt8) -> Bool { flags & flag == flag }
}

/// Reads and writes HTTP/2 frames. Holds no connection state beyond the read
/// size limit; the connection above decides what each frame means.
public final class HTTP2Framer {
    /// The client connection preface every HTTP/2 connection opens with.
    public static let clientPreface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    /// Size of a frame header: 24-bit length, type, flags, 31-bit stream id.
    public static let frameHeaderLength = 9
    /// The largest payload a 24-bit length field can declare, which is also
    /// x/net/http2's default read limit.
    public static let largestFrameLength = (1 << 24) - 1
    /// The peer's frame-size limit until it says otherwise (RFC 9113 6.5.2).
    public static let defaultMaxFrameSize = 16_384

    static let settingEntryLength = 6
    static let windowUpdateLength = 4
    static let rstStreamLength = 4
    static let goAwayMinimumLength = 8
    static let reservedBitMask: UInt32 = 0x7FFF_FFFF
    static let lengthFieldWidth = 3
    static let streamIDFieldWidth = 4

    private let transport: ByteTransport
    /// Frames declaring a longer payload are rejected before any buffer is sized.
    public var maxReadFrameSize: Int = HTTP2Framer.largestFrameLength

    public init(transport: ByteTransport) {
        self.transport = transport
    }

    // MARK: - Writing

    public func writePreface() throws {
        try transport.write(Self.clientPreface)
    }

    public func writeFrame(_ frame: HTTP2Frame) throws {
        try transport.write(Self.encode(frame))
    }

    public func writeSettings(_ settings: [(HTTP2SettingID, UInt32)]) throws {
        var payload: [UInt8] = []
        for (id, value) in settings {
            payload.appendUInt16BE(id.rawValue)
            payload.appendUInt32BE(value)
        }
        try writeFrame(HTTP2Frame(type: .settings, streamID: 0, payload: Data(payload)))
    }

    public func writeSettingsAck() throws {
        try writeFrame(HTTP2Frame(type: .settings, flags: HTTP2Flags.ack, streamID: 0))
    }

    public func writeWindowUpdate(streamID: UInt32, increment: UInt32) throws {
        var payload: [UInt8] = []
        payload.appendUInt32BE(increment & Self.reservedBitMask)
        try writeFrame(HTTP2Frame(type: .windowUpdate, streamID: streamID, payload: Data(payload)))
    }

    /// Opens a stream with an empty, complete header block, as go-ios does.
    public func writeHeaders(streamID: UInt32) throws {
        try writeFrame(HTTP2Frame(type: .headers, flags: HTTP2Flags.endHeaders, streamID: streamID))
    }

    public func writeData(streamID: UInt32, payload: Data) throws {
        try writeFrame(HTTP2Frame(type: .data, streamID: streamID, payload: payload))
    }

    /// Serialises a frame: 9-byte header then payload.
    public static func encode(_ frame: HTTP2Frame) -> Data {
        var header: [UInt8] = []
        header.appendBigEndian(UInt64(frame.payload.count), width: lengthFieldWidth)
        header.append(frame.rawType)
        header.append(frame.flags)
        header.appendUInt32BE(frame.streamID & reservedBitMask)
        return Data(header) + frame.payload
    }

    // MARK: - Reading

    /// Reads one frame, enforcing `maxReadFrameSize` and the payload shape of
    /// the control frames the connection interprets.
    public func readFrame() throws -> HTTP2Frame {
        let header = [UInt8](try transport.readExactly(Self.frameHeaderLength))
        let length = Int(header.bigEndianValue(at: 0, width: Self.lengthFieldWidth))
        guard length <= maxReadFrameSize else {
            throw HTTP2Error.frameTooLarge(length: length, limit: maxReadFrameSize)
        }
        let typeOffset = Self.lengthFieldWidth
        let streamOffset = typeOffset + 2
        let rawStream = UInt32(header.bigEndianValue(at: streamOffset, width: Self.streamIDFieldWidth))
        let payload = length == 0 ? Data() : try transport.readExactly(length)
        let frame = HTTP2Frame(
            rawType: header[typeOffset], flags: header[typeOffset + 1],
            streamID: rawStream & Self.reservedBitMask, payload: payload)
        try Self.validate(frame)
        return frame
    }

    private static func validate(_ frame: HTTP2Frame) throws {
        guard let type = frame.type else { return }
        let length = frame.payload.count
        switch type {
        case .settings:
            if frame.has(flag: HTTP2Flags.ack) && length != 0 {
                throw HTTP2Error.malformedFrame(type: frame.rawType, reason: "SETTINGS ack with a payload")
            }
            if length % settingEntryLength != 0 {
                throw HTTP2Error.malformedFrame(type: frame.rawType, reason: "SETTINGS length not a multiple of 6")
            }
        case .windowUpdate where length != windowUpdateLength:
            throw HTTP2Error.malformedFrame(type: frame.rawType, reason: "WINDOW_UPDATE length is not 4")
        case .rstStream where length != rstStreamLength:
            throw HTTP2Error.malformedFrame(type: frame.rawType, reason: "RST_STREAM length is not 4")
        case .goAway where length < goAwayMinimumLength:
            throw HTTP2Error.malformedFrame(type: frame.rawType, reason: "GOAWAY shorter than 8 bytes")
        default:
            return
        }
    }

    // MARK: - Payload helpers

    /// Parses a SETTINGS payload into id/value pairs, keeping unknown ids.
    public static func settings(in frame: HTTP2Frame) -> [(id: UInt16, value: UInt32)] {
        let bytes = [UInt8](frame.payload)
        return stride(from: 0, to: bytes.count, by: settingEntryLength).map { start in
            (UInt16(bytes.bigEndianValue(at: start, width: 2)),
             UInt32(bytes.bigEndianValue(at: start + 2, width: 4)))
        }
    }

    /// The application data of a DATA frame, with padding removed.
    public static func dataPayload(of frame: HTTP2Frame) throws -> Data {
        guard frame.has(flag: HTTP2Flags.padded) else { return frame.payload }
        let bytes = [UInt8](frame.payload)
        guard let padLength = bytes.first.map(Int.init), padLength < bytes.count else {
            throw HTTP2Error.malformedFrame(type: frame.rawType, reason: "padding exceeds payload")
        }
        return Data(bytes[1..<(bytes.count - padLength)])
    }

    /// The 32-bit big-endian word at `offset` of a control frame's payload.
    static func word(in frame: HTTP2Frame, at offset: Int) -> UInt32 {
        UInt32([UInt8](frame.payload).bigEndianValue(at: offset, width: 4))
    }
}
