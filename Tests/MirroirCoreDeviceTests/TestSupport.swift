// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Shared test doubles and helpers: an in-memory scripted transport, fixture loading, hex, JSON-to-XPC.
// ABOUTME: The scripted transport replays a device's bytes and records every byte the client writes.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation
import XCTest
@testable import MirroirCoreDevice

/// In-memory `ByteTransport` standing in for the TCP connection to a device.
/// It replays pre-scripted server bytes (a real device answers the RemoteXPC
/// handshake deterministically, so a script is representative) and records
/// what the client writes. Reading past the script behaves like a peer close.
final class ScriptedTransport: ByteTransport {
    private var inbound: Data
    private(set) var written = Data()
    private(set) var closed = false
    /// Largest chunk one `read` returns, to exercise short-read handling.
    let readChunk: Int

    init(inbound: Data = Data(), readChunk: Int = Int.max) {
        self.inbound = inbound
        self.readChunk = readChunk
    }

    func enqueue(_ data: Data) {
        inbound.append(data)
    }

    func write(_ data: Data) throws {
        guard !closed else { throw TransportError.closed }
        written.append(data)
    }

    func read(maximumLength: Int) throws -> Data {
        guard !closed, !inbound.isEmpty else { throw TransportError.closed }
        let count = min(maximumLength, readChunk, inbound.count)
        let chunk = inbound.prefix(count)
        inbound = Data(inbound.dropFirst(count))
        return Data(chunk)
    }

    func close() {
        closed = true
    }
}

/// Builds the bytes a device sends on the wire.
enum DeviceScript {
    /// The device's opening SETTINGS frame.
    static func settings(_ values: [(HTTP2SettingID, UInt32)] = [(.maxConcurrentStreams, 100)]) -> Data {
        var payload: [UInt8] = []
        for (id, value) in values {
            payload.appendUInt16BE(id.rawValue)
            payload.appendUInt32BE(value)
        }
        return HTTP2Framer.encode(HTTP2Frame(type: .settings, streamID: 0, payload: Data(payload)))
    }

    static func data(_ payload: Data, stream: RemoteXPCStream) -> Data {
        HTTP2Framer.encode(HTTP2Frame(type: .data, streamID: stream.rawValue, payload: payload))
    }

    static func message(_ message: RemoteXPCMessage, stream: RemoteXPCStream) throws -> Data {
        data(try XPCWireCodec.encodeMessage(message), stream: stream)
    }

    /// The three replies of the XPC init handshake, as a device sends them.
    static func handshakeReplies() throws -> Data {
        try message(RemoteXPCMessage(flags: .alwaysSet, body: RemoteXPCDictionary()), stream: .clientServer)
            + message(RemoteXPCMessage(flags: [.alwaysSet, .initHandshake], body: nil), stream: .serverClient)
            + message(RemoteXPCMessage(flags: .alwaysSet, body: nil), stream: .clientServer)
    }
}

enum Fixture {
    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
                                "missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }
}

enum Hex {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ text: String) throws -> Data {
        let characters = Array(text)
        guard characters.count.isMultiple(of: 2) else { throw CocoaError(.formatting) }
        var out = Data()
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else {
                throw CocoaError(.formatting)
            }
            out.append(byte)
        }
        return out
    }
}

/// Converts a JSON document into the XPC shape a device sends: objects become
/// dictionaries, integers `int64`, booleans `bool`, strings `string`.
enum JSONToXPC {
    static func convert(_ value: Any) throws -> RemoteXPCObject {
        switch value {
        case let dictionary as [String: Any]:
            var result = RemoteXPCDictionary()
            for key in dictionary.keys.sorted() {
                result[key] = try convert(dictionary[key] as Any)
            }
            return .dictionary(result)
        case let array as [Any]:
            return .array(try array.map(convert))
        case let text as String:
            return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .int64(number.int64Value)
        case is NSNull:
            return .null
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }
}

/// Records every HID report a session emits, and can be told to fail, to
/// exercise the paths that must lift contacts after a broken send. A fake is
/// needed because a real device never reports whether a report was applied.
final class RecordingHIDSender: HIDReportSending {
    struct Sent: Equatable {
        let report: Data
        let serviceID: UInt64
    }

    struct InjectedFailure: Error {}

    private(set) var sent: [Sent] = []
    private(set) var closeCount = 0
    /// 1-based index of the `sendReport` call that fails; 0 never fails.
    var failOnCall = 0
    private var calls = 0

    func sendReport(_ report: Data, serviceID: UInt64) throws {
        calls += 1
        if calls == failOnCall { throw InjectedFailure() }
        sent.append(Sent(report: report, serviceID: serviceID))
    }

    func close() {
        closeCount += 1
    }
}
