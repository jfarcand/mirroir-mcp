// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Encodes and decodes Apple's RemoteXPC wire format (wrapper header, body header, typed objects).
// ABOUTME: Ported from go-ios ios/xpc/encoding.go; every wire length is bounded before it drives an allocation.

import Foundation

/// Apple's XPC wire format as RemoteXPC carries it over HTTP/2.
///
/// A message is a 24-byte wrapper (magic, flags, body length, message id),
/// followed, when the body length is non-zero, by an 8-byte body header (object
/// magic and version) and one top-level dictionary. All integers are little
/// endian and every variable-length payload is padded to a 4-byte boundary.
public enum XPCWireCodec {
    /// Magic that opens every RemoteXPC message.
    public static let wrapperMagic: UInt32 = 0x29B0_0B92
    /// Magic that opens a message body.
    public static let objectMagic: UInt32 = 0x4213_3742
    /// The body version every observed device speaks.
    public static let bodyVersion: UInt32 = 0x0000_0005
    /// Size of the wrapper: magic, flags, body length and message id.
    public static let wrapperHeaderLength = 24
    /// Size of the body header: object magic and version.
    public static let bodyHeaderLength = 8
    /// Largest body this codec accepts from a peer. The body length is
    /// device-controlled, so it is capped before it sizes any buffer.
    public static let maximumBodyLength: UInt64 = 64 * 1024 * 1024
    /// Deepest container nesting the decoder follows before giving up, so a
    /// hostile body of nested dictionaries cannot exhaust the stack.
    public static let maximumNestingDepth = 64

    static let alignment = 4
    static let boolPaddingLength = 3

    /// Type tags of the XPC objects this codec understands.
    enum TypeTag: UInt32 {
        case null = 0x0000_1000
        case bool = 0x0000_2000
        case int64 = 0x0000_3000
        case uint64 = 0x0000_4000
        case double = 0x0000_5000
        case date = 0x0000_7000
        case data = 0x0000_8000
        case string = 0x0000_9000
        case uuid = 0x0000_A000
        case array = 0x0000_E000
        case dictionary = 0x0000_F000
        case fileTransfer = 0x0001_A000
    }

    /// Key under which a file-transfer descriptor carries its size.
    static let fileTransferSizeKey = "s"

    /// Bytes of padding needed to bring `length` to the next 4-byte boundary.
    static func padding(for length: Int) -> Int {
        (alignment - length % alignment) % alignment
    }

    // MARK: - Messages

    /// Encodes a complete message: wrapper, and body when present.
    public static func encodeMessage(_ message: RemoteXPCMessage) throws -> Data {
        var out: [UInt8] = []
        out.appendUInt32LE(wrapperMagic)
        out.appendUInt32LE(message.flags.rawValue)
        guard let body = message.body else {
            out.appendUInt64LE(0)
            out.appendUInt64LE(message.messageID)
            return Data(out)
        }
        var encodedBody: [UInt8] = []
        try encodeDictionary(body, into: &encodedBody)
        out.appendUInt64LE(UInt64(encodedBody.count + bodyHeaderLength))
        out.appendUInt64LE(message.messageID)
        out.appendUInt32LE(objectMagic)
        out.appendUInt32LE(bodyVersion)
        out.append(contentsOf: encodedBody)
        return Data(out)
    }

    /// Reads the body length out of a 24-byte wrapper, validating the magic and
    /// the length cap. Used by stream readers to know how much more to read.
    public static func bodyLength(ofWrapper header: Data) throws -> Int {
        var cursor = ByteCursor(header)
        let magic = try cursor.readUInt32LE()
        guard magic == wrapperMagic else { throw XPCCodecError.wrongWrapperMagic(magic) }
        _ = try cursor.readUInt32LE()
        let length = try cursor.readUInt64LE()
        guard length <= maximumBodyLength else {
            throw XPCCodecError.bodyLengthTooLarge(declared: length, limit: maximumBodyLength)
        }
        return Int(length)
    }

    /// Decodes one complete message. Bytes after the declared body are ignored.
    public static func decodeMessage(_ data: Data) throws -> RemoteXPCMessage {
        var cursor = ByteCursor(data)
        let magic = try cursor.readUInt32LE()
        guard magic == wrapperMagic else { throw XPCCodecError.wrongWrapperMagic(magic) }
        let flags = RemoteXPCMessageFlags(rawValue: try cursor.readUInt32LE())
        let bodyLength = try cursor.readUInt64LE()
        let messageID = try cursor.readUInt64LE()
        guard bodyLength != 0 else {
            return RemoteXPCMessage(flags: flags, messageID: messageID, body: nil)
        }
        let body = try decodeBody(&cursor, declaredLength: bodyLength)
        return RemoteXPCMessage(flags: flags, messageID: messageID, body: body)
    }

    private static func decodeBody(_ cursor: inout ByteCursor, declaredLength: UInt64) throws -> RemoteXPCDictionary {
        let magic = try cursor.readUInt32LE()
        guard magic == objectMagic else { throw XPCCodecError.wrongObjectMagic(magic) }
        let version = try cursor.readUInt32LE()
        guard version == bodyVersion else { throw XPCCodecError.unsupportedBodyVersion(version) }
        guard declaredLength >= UInt64(bodyHeaderLength) else {
            throw XPCCodecError.bodyLengthTooSmall(declaredLength)
        }
        guard declaredLength <= maximumBodyLength else {
            throw XPCCodecError.bodyLengthTooLarge(declared: declaredLength, limit: maximumBodyLength)
        }
        let payloadLength = Int(declaredLength) - bodyHeaderLength
        var payload = ByteCursor(try cursor.readBytes(payloadLength))
        guard case .dictionary(let dictionary) = try decodeObject(&payload, depth: 0) else {
            throw XPCCodecError.topLevelNotDictionary
        }
        return dictionary
    }

    // MARK: - Decoding objects

    static func decodeObject(_ cursor: inout ByteCursor, depth: Int) throws -> RemoteXPCObject {
        guard depth <= maximumNestingDepth else {
            throw XPCCodecError.nestingTooDeep(limit: maximumNestingDepth)
        }
        let rawType = try cursor.readUInt32LE()
        guard let type = TypeTag(rawValue: rawType) else { throw XPCCodecError.unknownType(rawType) }
        switch type {
        case .null:
            return .null
        case .bool:
            let value = try cursor.readUInt8() != 0
            cursor.skipLeniently(boolPaddingLength)
            return .bool(value)
        case .int64:
            return .int64(Int64(bitPattern: try cursor.readUInt64LE()))
        case .uint64:
            return .uint64(try cursor.readUInt64LE())
        case .double:
            return .double(Double(bitPattern: try cursor.readUInt64LE()))
        case .date:
            return .date(nanosecondsSince1970: Int64(bitPattern: try cursor.readUInt64LE()))
        case .data:
            return .data(try decodeData(&cursor))
        case .string:
            return .string(try decodeString(&cursor))
        case .uuid:
            return .uuid(try decodeUUID(&cursor))
        case .array:
            return .array(try decodeArray(&cursor, depth: depth))
        case .dictionary:
            return .dictionary(try decodeDictionary(&cursor, depth: depth))
        case .fileTransfer:
            return try decodeFileTransfer(&cursor, depth: depth)
        }
    }

    private static func readBoundedLength(_ cursor: inout ByteCursor, field: String) throws -> Int {
        let length = try cursor.readUInt32LE()
        guard Int(length) <= cursor.remaining else {
            throw XPCCodecError.lengthExceedsRemaining(field: field, length: length, remaining: cursor.remaining)
        }
        return Int(length)
    }

    private static func decodeData(_ cursor: inout ByteCursor) throws -> Data {
        let length = try readBoundedLength(&cursor, field: "data")
        let bytes = try cursor.readBytes(length)
        cursor.skipLeniently(padding(for: length))
        return Data(bytes)
    }

    private static func decodeString(_ cursor: inout ByteCursor) throws -> String {
        let length = try readBoundedLength(&cursor, field: "string")
        var bytes = try cursor.readBytes(length)
        while bytes.last == 0 { bytes.removeLast() }
        try cursor.skip(padding(for: length))
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw XPCCodecError.invalidUTF8(field: "string")
        }
        return value
    }

    private static func decodeUUID(_ cursor: inout ByteCursor) throws -> UUID {
        let b = try cursor.readBytes(MemoryLayout<uuid_t>.size)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private static func readEntryCount(_ cursor: inout ByteCursor, container: String) throws -> Int {
        _ = try readBoundedLength(&cursor, field: container)
        let count = try cursor.readUInt32LE()
        guard Int(count) <= cursor.remaining else {
            throw XPCCodecError.entryCountExceedsRemaining(
                container: container, count: count, remaining: cursor.remaining)
        }
        return Int(count)
    }

    private static func decodeArray(_ cursor: inout ByteCursor, depth: Int) throws -> [RemoteXPCObject] {
        let count = try readEntryCount(&cursor, container: "array")
        var result: [RemoteXPCObject] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try decodeObject(&cursor, depth: depth + 1))
        }
        return result
    }

    private static func decodeDictionary(_ cursor: inout ByteCursor, depth: Int) throws -> RemoteXPCDictionary {
        let count = try readEntryCount(&cursor, container: "dictionary")
        var result = RemoteXPCDictionary()
        for _ in 0..<count {
            let keyBytes = try cursor.readNulTerminated()
            try cursor.skip(padding(for: keyBytes.count + 1))
            guard let key = String(bytes: keyBytes, encoding: .utf8) else {
                throw XPCCodecError.invalidUTF8(field: "dictionary key")
            }
            result[key] = try decodeObject(&cursor, depth: depth + 1)
        }
        return result
    }

    private static func decodeFileTransfer(_ cursor: inout ByteCursor, depth: Int) throws -> RemoteXPCObject {
        let messageID = try cursor.readUInt64LE()
        guard case .dictionary(let descriptor) = try decodeObject(&cursor, depth: depth + 1),
              case .uint64(let size)? = descriptor[fileTransferSizeKey] else {
            throw XPCCodecError.malformedFileTransfer
        }
        return .fileTransfer(messageID: messageID, transferSize: size)
    }

    // MARK: - Encoding objects

    static func encodeObject(_ object: RemoteXPCObject, into out: inout [UInt8]) throws {
        switch object {
        case .null:
            out.appendUInt32LE(TypeTag.null.rawValue)
        case .bool(let value):
            out.appendUInt32LE(TypeTag.bool.rawValue)
            out.append(value ? 1 : 0)
            out.append(contentsOf: [UInt8](repeating: 0, count: boolPaddingLength))
        case .int64(let value):
            out.appendUInt32LE(TypeTag.int64.rawValue)
            out.appendUInt64LE(UInt64(bitPattern: value))
        case .uint64(let value):
            out.appendUInt32LE(TypeTag.uint64.rawValue)
            out.appendUInt64LE(value)
        case .double(let value):
            out.appendUInt32LE(TypeTag.double.rawValue)
            out.appendUInt64LE(value.bitPattern)
        case .date(let nanoseconds):
            out.appendUInt32LE(TypeTag.date.rawValue)
            out.appendUInt64LE(UInt64(bitPattern: nanoseconds))
        case .data(let value):
            out.appendUInt32LE(TypeTag.data.rawValue)
            try appendPadded([UInt8](value), declaredLength: value.count, field: "data", into: &out)
        case .string(let value):
            out.appendUInt32LE(TypeTag.string.rawValue)
            let bytes = Array(value.utf8) + [0]
            try appendPadded(bytes, declaredLength: bytes.count, field: "string", into: &out)
        case .uuid(let value):
            out.appendUInt32LE(TypeTag.uuid.rawValue)
            out.append(contentsOf: withUnsafeBytes(of: value.uuid) { Array($0) })
        case .array(let values):
            try encodeArray(values, into: &out)
        case .dictionary(let value):
            try encodeDictionary(value, into: &out)
        case .fileTransfer(let messageID, let size):
            out.appendUInt32LE(TypeTag.fileTransfer.rawValue)
            out.appendUInt64LE(messageID)
            try encodeDictionary([fileTransferSizeKey: .uint64(size)], into: &out)
        }
    }

    private static func appendPadded(
        _ bytes: [UInt8], declaredLength: Int, field: String, into out: inout [UInt8]
    ) throws {
        guard let length = UInt32(exactly: declaredLength) else {
            throw XPCCodecError.valueTooLarge(field: field, length: declaredLength)
        }
        out.appendUInt32LE(length)
        out.append(contentsOf: bytes)
        out.append(contentsOf: [UInt8](repeating: 0, count: padding(for: bytes.count)))
    }

    /// Arrays declare a payload length that includes their 4-byte entry count.
    /// This follows the captured device bytes (`xpc_dict.bin`: an empty array
    /// declares length 4); go-ios writes the length without the count, which
    /// its decoder, like this one, never reads back.
    private static func encodeArray(_ values: [RemoteXPCObject], into out: inout [UInt8]) throws {
        var payload: [UInt8] = []
        payload.appendUInt32LE(UInt32(values.count))
        for value in values {
            try encodeObject(value, into: &payload)
        }
        out.appendUInt32LE(TypeTag.array.rawValue)
        try appendLength(payload.count, field: "array", into: &out)
        out.append(contentsOf: payload)
    }

    static func encodeDictionary(_ dictionary: RemoteXPCDictionary, into out: inout [UInt8]) throws {
        var payload: [UInt8] = []
        payload.appendUInt32LE(UInt32(dictionary.count))
        for entry in dictionary.entries {
            let key = Array(entry.key.utf8) + [0]
            payload.append(contentsOf: key)
            payload.append(contentsOf: [UInt8](repeating: 0, count: padding(for: key.count)))
            try encodeObject(entry.value, into: &payload)
        }
        out.appendUInt32LE(TypeTag.dictionary.rawValue)
        try appendLength(payload.count, field: "dictionary", into: &out)
        out.append(contentsOf: payload)
    }

    private static func appendLength(_ length: Int, field: String, into out: inout [UInt8]) throws {
        guard let value = UInt32(exactly: length) else {
            throw XPCCodecError.valueTooLarge(field: field, length: length)
        }
        out.appendUInt32LE(value)
    }
}
