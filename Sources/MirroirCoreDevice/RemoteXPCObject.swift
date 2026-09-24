// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Value model for RemoteXPC messages: the XPC object enum, an insertion-ordered dictionary, and message flags.
// ABOUTME: Dictionaries keep wire order so a decoded message re-encodes byte-for-byte; equality ignores order.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation

/// One XPC object as it travels inside a RemoteXPC message.
///
/// Integer widths are distinct cases on purpose: the device's Swift decoders are
/// strict, and a `uint64` sent where an `int64` is expected is rejected there.
public indirect enum RemoteXPCObject: Equatable, Sendable {
    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    /// Nanoseconds since the Unix epoch, as go-ios decodes the date type.
    case date(nanosecondsSince1970: Int64)
    case data(Data)
    case string(String)
    case uuid(UUID)
    case array([RemoteXPCObject])
    case dictionary(RemoteXPCDictionary)
    /// A file-transfer descriptor: the message id of the transfer and its size in bytes.
    case fileTransfer(messageID: UInt64, transferSize: UInt64)

    /// The dictionary payload, when this object is a dictionary.
    public var dictionaryValue: RemoteXPCDictionary? {
        if case .dictionary(let value) = self { return value }
        return nil
    }

    /// The string payload, when this object is a string.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The data payload, when this object is data.
    public var dataValue: Data? {
        if case .data(let value) = self { return value }
        return nil
    }

    /// The array payload, when this object is an array.
    public var arrayValue: [RemoteXPCObject]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

/// One key/value pair of an `RemoteXPCDictionary`, in wire order.
public struct RemoteXPCDictionaryEntry: Equatable, Sendable {
    public let key: String
    public let value: RemoteXPCObject

    public init(key: String, value: RemoteXPCObject) {
        self.key = key
        self.value = value
    }
}

/// An XPC dictionary that remembers insertion order.
///
/// The order is what the encoder writes, so a decoded message re-encodes to the
/// bytes it came from. Equality compares contents only, because two senders may
/// legitimately order the same keys differently. A key-to-position index keeps
/// lookups and inserts constant-time, so decoding a peer-supplied dictionary is
/// linear in its entry count.
public struct RemoteXPCDictionary: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    public private(set) var entries: [RemoteXPCDictionaryEntry]
    /// Position of each key in `entries`.
    private var positions: [String: Int]

    public init() {
        entries = []
        positions = [:]
    }

    public init(_ entries: [(String, RemoteXPCObject)]) {
        self.init()
        self.entries.reserveCapacity(entries.count)
        positions.reserveCapacity(entries.count)
        for (key, value) in entries {
            self[key] = value
        }
    }

    public init(dictionaryLiteral elements: (String, RemoteXPCObject)...) {
        self.init(elements)
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var keys: [String] { entries.map(\.key) }

    /// Reads a value, or replaces it in place (keeping its position), or appends
    /// a new key at the end. Assigning `nil` removes the key, which shifts the
    /// positions of the keys after it.
    public subscript(key: String) -> RemoteXPCObject? {
        get { positions[key].map { entries[$0].value } }
        set {
            switch (positions[key], newValue) {
            case let (index?, value?):
                entries[index] = RemoteXPCDictionaryEntry(key: key, value: value)
            case let (index?, nil):
                entries.remove(at: index)
                positions[key] = nil
                for shifted in index..<entries.count {
                    positions[entries[shifted].key] = shifted
                }
            case let (nil, value?):
                positions[key] = entries.count
                entries.append(RemoteXPCDictionaryEntry(key: key, value: value))
            case (nil, nil):
                break
            }
        }
    }

    public static func == (lhs: RemoteXPCDictionary, rhs: RemoteXPCDictionary) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.entries.allSatisfy { rhs[$0.key] == $0.value }
    }
}

/// The flag word of a RemoteXPC message header.
public struct RemoteXPCMessageFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Set on every message a client sends.
    public static let alwaysSet = RemoteXPCMessageFlags(rawValue: 0x0000_0001)
    /// The message carries a body.
    public static let data = RemoteXPCMessageFlags(rawValue: 0x0000_0100)
    /// Sent as the third init-handshake message on the client-server stream.
    /// Its meaning is unpublished; go-ios and pymobiledevice3 both send `0x201`.
    public static let handshakeCompletion = RemoteXPCMessageFlags(rawValue: 0x0000_0200)
    /// The sender wants a reply (go-ios: HeartbeatRequestFlag).
    public static let heartbeatRequest = RemoteXPCMessageFlags(rawValue: 0x0001_0000)
    /// The message is a reply (go-ios: HeartbeatReplyFlag).
    public static let heartbeatReply = RemoteXPCMessageFlags(rawValue: 0x0002_0000)
    /// The message opens a file transfer.
    public static let fileOpen = RemoteXPCMessageFlags(rawValue: 0x0010_0000)
    /// Marks the init-handshake message on the server-client stream.
    public static let initHandshake = RemoteXPCMessageFlags(rawValue: 0x0040_0000)
}

/// A complete RemoteXPC message: header flags, message id and optional body.
public struct RemoteXPCMessage: Equatable, Sendable {
    public var flags: RemoteXPCMessageFlags
    public var messageID: UInt64
    /// `nil` encodes as a header with a zero body length.
    public var body: RemoteXPCDictionary?

    public init(flags: RemoteXPCMessageFlags, messageID: UInt64 = 0, body: RemoteXPCDictionary?) {
        self.flags = flags
        self.messageID = messageID
        self.body = body
    }
}
