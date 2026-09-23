// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Encodes the AVConference video negotiator offer the display service needs to start a media stream.
// ABOUTME: Exact port of go-ios ios/display/offer.go: schema-less protobuf media blob, zlib level 9, binary plist.

import Foundation
import zlib

/// The negotiator offer sent in a `startmediastream` request.
///
/// The daemon rejects any deviation with an opaque "Invalid Parameter" that
/// names no field, so the media blob is pinned byte-for-byte by a golden test
/// against the offer Xcode sent (go-ios `offer_test.go`).
public enum DisplayStreamOffer {
    /// `avcMediaStreamNegotiatorMode` for video (audio would be 6).
    public static let negotiatorModeVideo = 5
    /// Apple's decoder string; the device matches on it.
    public static let decoderName = "Viceroy 1.7.0"
    /// AVConference codec-capability id, identical in every captured offer.
    static let resEntryCodecCapID: UInt64 = 50_115
    /// Per-bank capability flags; "FLS;" is AVConference's framing marker.
    static let hevcFeatures = "FLS;SW:1;"
    static let avcFeatures = "FLS;VRAE:0;SW:1;"
    /// RTP payload types of the two advertised banks; iOS 27 picks AVC.
    static let hevcPayloadType: UInt64 = 123
    static let avcPayloadType: UInt64 = 100
    static let hevcTrailer: UInt64 = 1
    static let avcTrailer: UInt64 = 14
    static let hevcResPairCount = 4
    static let avcResPairCount = 2
    /// Host clock value from the capture; the daemon does not appear to check it.
    public static let capturedVideoTimestamp: UInt64 = 17_137_042_128_614_416_384
    /// The session id is written as a varint padded to this many bytes, so it
    /// can be rewritten in place.
    static let sessionIDVarintWidth = 5
    static let settingsMaxBitrateFlag: UInt64 = 63
    static let blobTrailerMode: UInt64 = 2

    /// What the device is told the host is. Xcode's values.
    public static let hostModel = "Mac15,9"
    public static let hostOSVersion = "2205.3.1"
    public static let hostBuild = "25F80"

    static let remoteEndpointInfoKey = "avcMediaStreamOptionRemoteEndpointInfo"
    static let negotiatorModeKey = "avcMediaStreamNegotiatorMode"
    static let mediaBlobKey = "avcMediaStreamNegotiatorMediaBlob"
    static let callIDKey = "avcMediaStreamOptionCallID"

    /// One entry of the media blob's bitrate tier table. `kind` 0 carries a
    /// bitrate cap; the other kinds are unidentified markers.
    struct BitrateTier {
        let kind: UInt64
        let bps: UInt64
        let bufferCap: UInt64?
    }

    /// Apple's tier table, in the significant order it was captured in.
    static let videoBitrateTiers: [BitrateTier] = [
        BitrateTier(kind: 4074, bps: 0, bufferCap: 16384),
        BitrateTier(kind: 0, bps: 75_000_000, bufferCap: 524_288),
        BitrateTier(kind: 0, bps: 40_000_000, bufferCap: 12288),
        BitrateTier(kind: 16, bps: 4100, bufferCap: nil),
        BitrateTier(kind: 0, bps: 20_000_000, bufferCap: 98304),
        BitrateTier(kind: 4, bps: 6500, bufferCap: nil),
        BitrateTier(kind: 0, bps: 6_000_000, bufferCap: 131_072),
        BitrateTier(kind: 0, bps: 100_000_000, bufferCap: 1_048_576),
        BitrateTier(kind: 0, bps: 60_000_000, bufferCap: 262_144),
        BitrateTier(kind: 1, bps: 299, bufferCap: nil),
    ]

    /// The media blob's tunable flags.
    public struct VideoBlobParameters: Sendable {
        public var sessionID: UInt32
        public var allowRTCPFeedback = false
        /// Long-term reference frames; off by default because under UDP loss
        /// they leave the picture torn.
        public var longTermReferenceFrames = false
        public var forwardErrorCorrection = true
        public var tilesPerFrame: UInt64 = 1
        public var timestamp = DisplayStreamOffer.capturedVideoTimestamp

        public init(sessionID: UInt32) {
            self.sessionID = sessionID
        }
    }

    // MARK: - Media blob

    /// The uncompressed media blob.
    public static func videoMediaBlob(_ parameters: VideoBlobParameters) -> Data {
        var blob = Protobuf()
        blob.varint(1, 1)
        blob.varint(2, 1)
        blob.bytes(5, videoSettings(parameters))
        blob.string(6, decoderName)
        blob.varint(8, 0)
        for tier in videoBitrateTiers {
            var entry = Protobuf()
            entry.varint(1, tier.kind)
            entry.varint(2, tier.bps)
            if let cap = tier.bufferCap { entry.varint(3, cap) }
            blob.bytes(9, entry.bytes)
        }
        blob.varint(13, parameters.timestamp)
        blob.varint(14, blobTrailerMode)
        blob.varint(16, 0)
        blob.varint(18, 1)
        return Data(blob.bytes)
    }

    static func videoSettings(_ parameters: VideoBlobParameters) -> [UInt8] {
        var settings = Protobuf()
        settings.paddedVarint(1, UInt64(parameters.sessionID), width: sessionIDVarintWidth)
        settings.bool(2, parameters.allowRTCPFeedback)
        settings.bytes(3, codecBank(hevcPayloadType, hevcFeatures, hevcTrailer, hevcResPairCount))
        settings.bytes(3, codecBank(avcPayloadType, avcFeatures, avcTrailer, avcResPairCount))
        if parameters.tilesPerFrame != 1 { settings.varint(6, parameters.tilesPerFrame) }
        settings.bool(7, parameters.longTermReferenceFrames)
        settings.varint(8, settingsMaxBitrateFlag)
        if parameters.forwardErrorCorrection { settings.varint(10, 1) }
        settings.varint(12, 1)
        return settings.bytes
    }

    /// One codec bank: payload type, alternating resolution-pair entries 1, 2,
    /// ... repeated `pairCount` times, feature string, trailer.
    static func codecBank(_ payloadType: UInt64, _ features: String, _ trailer: UInt64, _ pairCount: Int) -> [UInt8] {
        var bank = Protobuf()
        bank.varint(1, payloadType)
        for index in 0..<pairCount {
            var entry = Protobuf()
            entry.varint(1, 1)
            entry.varint(2, UInt64(1 + index % 2))
            entry.varint(3, resEntryCodecCapID)
            entry.varint(4, 0)
            bank.bytes(2, entry.bytes)
        }
        bank.string(3, features)
        bank.varint(4, trailer)
        return bank.bytes
    }

    /// The `avcMediaStreamOptionRemoteEndpointInfo` protobuf describing the host.
    public static func remoteEndpointInfo() -> Data {
        var info = Protobuf()
        info.varint(1, 0)
        info.varint(2, 1)
        info.string(3, hostModel)
        info.string(4, hostOSVersion)
        info.string(5, hostBuild)
        return Data(info.bytes)
    }

    // MARK: - Offer

    /// The complete offer: a binary plist with the endpoint info, video mode,
    /// compressed media blob and upper-case call id.
    public static func videoNegotiatorOffer(callID: UUID, sessionID: UInt32) throws -> Data {
        let blob = try compress(videoMediaBlob(VideoBlobParameters(sessionID: sessionID)))
        let offer: [String: Any] = [
            remoteEndpointInfoKey: remoteEndpointInfo(),
            negotiatorModeKey: negotiatorModeVideo,
            mediaBlobKey: blob,
            callIDKey: callID.uuidString.uppercased(),
        ]
        do {
            return try PropertyListSerialization.data(fromPropertyList: offer, format: .binary, options: 0)
        } catch {
            throw DisplayStreamError.plistEncodingFailed(reason: "\(error)")
        }
    }

    /// zlib (RFC 1950) at best compression. The device rejects any other
    /// level; the stream header advertises the level (0x78 0xDA).
    public static func compress(_ blob: Data) throws -> Data {
        var source = [UInt8](blob)
        var destinationLength = compressBound(uLong(source.count))
        var destination = [UInt8](repeating: 0, count: Int(destinationLength))
        let status = compress2(&destination, &destinationLength, &source, uLong(source.count), Z_BEST_COMPRESSION)
        guard status == Z_OK else { throw DisplayStreamError.compressionFailed(status: status) }
        return Data(destination.prefix(Int(destinationLength)))
    }
}

/// A minimal protobuf writer: the field shapes the offer uses, nothing more.
struct Protobuf {
    static let varintWireType: UInt64 = 0
    static let lengthDelimitedWireType: UInt64 = 2
    static let tagShift: UInt64 = 3
    static let payloadBits: UInt64 = 7
    static let payloadMask: UInt64 = 0x7F
    static let continuationBit: UInt8 = 0x80

    private(set) var bytes: [UInt8] = []

    mutating func varint(_ field: UInt64, _ value: UInt64) {
        appendTag(field, Self.varintWireType)
        bytes.append(contentsOf: Self.encodeVarint(value))
    }

    mutating func bool(_ field: UInt64, _ value: Bool) {
        varint(field, value ? 1 : 0)
    }

    mutating func bytes(_ field: UInt64, _ value: [UInt8]) {
        appendTag(field, Self.lengthDelimitedWireType)
        bytes.append(contentsOf: Self.encodeVarint(UInt64(value.count)))
        bytes.append(contentsOf: value)
    }

    mutating func string(_ field: UInt64, _ value: String) {
        bytes(field, Array(value.utf8))
    }

    /// A varint padded to `width` bytes with continuation bytes that add
    /// nothing, so its value can be rewritten in place.
    mutating func paddedVarint(_ field: UInt64, _ value: UInt64, width: Int) {
        appendTag(field, Self.varintWireType)
        bytes.append(contentsOf: Self.paddedVarint(value, width: width))
    }

    private mutating func appendTag(_ field: UInt64, _ wireType: UInt64) {
        bytes.append(contentsOf: Self.encodeVarint(field << Self.tagShift | wireType))
    }

    static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & payloadMask)
            remaining >>= payloadBits
            if remaining != 0 { byte |= continuationBit }
            out.append(byte)
        } while remaining != 0
        return out
    }

    /// `value` must fit in 7 × `width` bits.
    static func paddedVarint(_ value: UInt64, width: Int) -> [UInt8] {
        var encoded = encodeVarint(value)
        while encoded.count < width {
            encoded[encoded.count - 1] |= continuationBit
            encoded.append(0)
        }
        return encoded
    }
}
