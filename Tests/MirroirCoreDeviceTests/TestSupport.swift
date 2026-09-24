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

/// A `ByteTransport` that behaves like a device answering requests: each reply
/// is released only after the client has written a DATA frame on the stream the
/// reply is gated on, in order. A client that reads before writing the request
/// finds nothing to read (a peer close), and one that writes on the wrong
/// stream never unlocks the reply, so ordering mistakes fail the test.
final class GatedTransport: ByteTransport {
    struct Gate {
        /// Stream the client must write a DATA frame on to release `reply`.
        let stream: RemoteXPCStream
        let reply: Data
    }

    private let inner: ScriptedTransport
    private var gates: [Gate]
    private var parsedOffset = HTTP2Framer.clientPreface.count
    /// DATA-frame streams the client wrote that did not match the next gate.
    private(set) var outOfOrderStreams: [UInt32] = []

    /// - Parameters:
    ///   - initial: bytes available before the client writes anything (the
    ///     device's opening SETTINGS).
    ///   - gates: replies, each released by the matching client write.
    init(initial: Data, gates: [Gate]) {
        self.inner = ScriptedTransport(inbound: initial)
        self.gates = gates
    }

    var written: Data { inner.written }
    var closed: Bool { inner.closed }
    var remainingGates: Int { gates.count }

    func write(_ data: Data) throws {
        try inner.write(data)
        releaseRepliesForCompleteFrames()
    }

    func read(maximumLength: Int) throws -> Data {
        try inner.read(maximumLength: maximumLength)
    }

    func close() {
        inner.close()
    }

    private func releaseRepliesForCompleteFrames() {
        let bytes = [UInt8](inner.written)
        while bytes.count - parsedOffset >= HTTP2Framer.frameHeaderLength {
            let length = Int(bytes.bigEndianValue(at: parsedOffset, width: HTTP2Framer.lengthFieldWidth))
            let end = parsedOffset + HTTP2Framer.frameHeaderLength + length
            guard end <= bytes.count else { return }
            let type = bytes[parsedOffset + HTTP2Framer.lengthFieldWidth]
            let stream = UInt32(bytes.bigEndianValue(
                at: parsedOffset + HTTP2Framer.lengthFieldWidth + 2, width: HTTP2Framer.streamIDFieldWidth))
            parsedOffset = end
            guard type == HTTP2FrameType.data.rawValue else { continue }
            guard let gate = gates.first, gate.stream.rawValue == stream else {
                outOfOrderStreams.append(stream)
                continue
            }
            gates.removeFirst()
            inner.enqueue(gate.reply)
        }
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

    /// The three init-handshake replies, each gated on the client request it answers.
    static func handshakeGates() throws -> [GatedTransport.Gate] {
        [
            GatedTransport.Gate(stream: .clientServer, reply: try message(
                RemoteXPCMessage(flags: .alwaysSet, body: RemoteXPCDictionary()), stream: .clientServer)),
            GatedTransport.Gate(stream: .serverClient, reply: try message(
                RemoteXPCMessage(flags: [.alwaysSet, .initHandshake], body: nil), stream: .serverClient)),
            GatedTransport.Gate(stream: .clientServer, reply: try message(
                RemoteXPCMessage(flags: .alwaysSet, body: nil), stream: .clientServer)),
        ]
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

    struct InjectedFailure: Error, Equatable {
        let call: Int
    }

    private(set) var sent: [Sent] = []
    private(set) var closeCount = 0
    /// 1-based indexes of the `sendReport` calls that fail.
    var failingCalls: Set<Int> = []
    private var calls = 0

    func sendReport(_ report: Data, serviceID: UInt64) throws {
        calls += 1
        if failingCalls.contains(calls) { throw InjectedFailure(call: calls) }
        sent.append(Sent(report: report, serviceID: serviceID))
    }

    func close() {
        closeCount += 1
    }
}
