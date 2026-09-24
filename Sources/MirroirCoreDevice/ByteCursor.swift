// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Bounds-checked little/big-endian reader and writer helpers over byte buffers.
// ABOUTME: Every read checks the remaining length first, so malformed input throws instead of trapping.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation

/// A forward-only reader over a byte array. Every read is bounds checked and
/// throws `XPCCodecError.truncated` rather than reading past the end.
struct ByteCursor {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    init(_ data: Data) {
        self.init([UInt8](data))
    }

    /// Bytes left between the cursor and the end of the buffer.
    var remaining: Int { bytes.count - offset }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else {
            throw XPCCodecError.truncated(offset: offset, needed: count, available: remaining)
        }
        let slice = Array(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    mutating func skip(_ count: Int) throws {
        _ = try readBytes(count)
    }

    /// Skips up to `count` bytes, stopping at the end of the buffer. Used for
    /// trailing alignment padding a sender may omit at the very end of a body.
    mutating func skipLeniently(_ count: Int) {
        offset += min(max(count, 0), remaining)
    }

    mutating func readUInt8() throws -> UInt8 {
        try readBytes(1)[0]
    }

    mutating func readUInt32LE() throws -> UInt32 {
        UInt32(truncatingIfNeeded: try readLittleEndian(width: 4))
    }

    mutating func readUInt64LE() throws -> UInt64 {
        try readLittleEndian(width: 8)
    }

    /// Reads bytes up to and including the next NUL, returning them without the NUL.
    mutating func readNulTerminated() throws -> [UInt8] {
        guard let end = bytes[offset...].firstIndex(of: 0) else {
            throw XPCCodecError.unterminatedKey
        }
        let value = Array(bytes[offset..<end])
        offset = end + 1
        return value
    }

    private mutating func readLittleEndian(width: Int) throws -> UInt64 {
        let raw = try readBytes(width)
        var value: UInt64 = 0
        for (index, byte) in raw.enumerated() {
            value |= UInt64(byte) << (UInt64(index) * UInt64(UInt8.bitWidth))
        }
        return value
    }
}

extension Array where Element == UInt8 {
    mutating func appendUInt16LE(_ value: UInt16) {
        appendLittleEndian(UInt64(value), width: MemoryLayout<UInt16>.size)
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        appendLittleEndian(UInt64(value), width: MemoryLayout<UInt32>.size)
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        appendLittleEndian(value, width: MemoryLayout<UInt64>.size)
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        appendBigEndian(UInt64(value), width: MemoryLayout<UInt32>.size)
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        appendBigEndian(UInt64(value), width: MemoryLayout<UInt16>.size)
    }

    /// Writes the low `width` bytes of `value`, least significant first.
    mutating func appendLittleEndian(_ value: UInt64, width: Int) {
        for index in 0..<width {
            append(UInt8(truncatingIfNeeded: value >> (UInt64(index) * UInt64(UInt8.bitWidth))))
        }
    }

    /// Writes the low `width` bytes of `value`, most significant first.
    mutating func appendBigEndian(_ value: UInt64, width: Int) {
        for index in stride(from: width - 1, through: 0, by: -1) {
            append(UInt8(truncatingIfNeeded: value >> (UInt64(index) * UInt64(UInt8.bitWidth))))
        }
    }

    /// Reads a big-endian unsigned integer of `width` bytes starting at `start`.
    /// The caller guarantees the range is in bounds.
    func bigEndianValue(at start: Int, width: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in start..<(start + width) {
            value = (value << UInt64(UInt8.bitWidth)) | UInt64(self[index])
        }
        return value
    }
}
