// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: XPC wire codec tests: go-ios captured fixtures decoded and re-encoded byte-for-byte, plus round trips.
// ABOUTME: Mirrors go-ios ios/xpc/encoding_test.go vectors; malformed-input tests live in XPCWireCodecSecurityTests.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation
import XCTest
@testable import MirroirCoreDevice

final class XPCWireCodecTests: XCTestCase {

    // MARK: - Captured fixtures (go-ios xpc_empty_dict.bin, xpc_dict.bin)

    func testEmptyDictionaryFixture() throws {
        let bytes = try Fixture.data("xpc_empty_dict", "bin")
        let message = try XPCWireCodec.decodeMessage(bytes)
        XCTAssertEqual(message.flags, .alwaysSet)
        XCTAssertEqual(message.body, RemoteXPCDictionary())
        XCTAssertEqual(try XPCWireCodec.encodeMessage(message), bytes, "re-encoding must reproduce the capture")
    }

    func testDictionaryFixtureDecodesToGoIOSExpectation() throws {
        let message = try XPCWireCodec.decodeMessage(try Fixture.data("xpc_dict", "bin"))
        XCTAssertEqual(message.flags, [.alwaysSet, .data, .heartbeatRequest])
        XCTAssertEqual(message.messageID, 1)
        XCTAssertEqual(message.body, try Self.goIOSDictionaryExpectation())
    }

    /// The decoder keeps wire order, so the capture re-encodes to itself. This
    /// pins the encoder to Apple's bytes, including the array length field
    /// (which counts the 4-byte entry count, unlike go-ios's encoder).
    func testDictionaryFixtureReencodesByteForByte() throws {
        let bytes = try Fixture.data("xpc_dict", "bin")
        let reencoded = try XPCWireCodec.encodeMessage(try XPCWireCodec.decodeMessage(bytes))
        XCTAssertEqual(Hex.encode(reencoded), Hex.encode(bytes))
    }

    /// go-ios `TestDictionary`'s expected map.
    static func goIOSDictionaryExpectation() throws -> RemoteXPCDictionary {
        let plistOptions = try XCTUnwrap(Data(base64Encoded: "YnBsaXN0MDDQCAAAAAAAAAEBAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAJ"))
        let options: RemoteXPCDictionary = [
            "arguments": .array([]),
            "environmentVariables": .dictionary(["TERM": .string("xterm-256color")]),
            "platformSpecificOptions": .data(plistOptions),
            "standardIOUsesPseudoterminals": .bool(true),
            "startStopped": .bool(false),
            "terminateExisting": .bool(false),
            "user": .dictionary(["active": .bool(true)]),
            "workingDirectory": .null,
        ]
        let input: RemoteXPCDictionary = [
            "applicationSpecifier": .dictionary([
                "bundleIdentifier": .dictionary(["_0": .string("xxx.xxxxxxxxx.xxxxxxxx")]),
            ]),
            "options": .dictionary(options),
            "standardIOIdentifiers": .dictionary(RemoteXPCDictionary()),
        ]
        return [
            "CoreDevice.CoreDeviceDDIProtocolVersion": .int64(0),
            "CoreDevice.action": .dictionary(RemoteXPCDictionary()),
            "CoreDevice.coreDeviceVersion": .dictionary([
                "components": .array([.uint64(0x15C), .uint64(1), .uint64(0), .uint64(0), .uint64(0)]),
                "originalComponentsCount": .int64(2),
                "stringValue": .string("348.1"),
            ]),
            "CoreDevice.deviceIdentifier": .string("A7DD28AC-2911-4549-811D-85917B9AC72F"),
            "CoreDevice.featureIdentifier": .string("com.apple.coredevice.feature.launchapplication"),
            "CoreDevice.input": .dictionary(input),
            "CoreDevice.invocationIdentifier": .string("62419FC1-5ABF-4D96-BCA8-7A5F6F9A69EE"),
        ]
    }

    // MARK: - go-ios TestEncodeDecode vectors

    func testGoIOSRoundTripVectors() throws {
        let uuidBytes = try XCTUnwrap(Data(base64Encoded: "RYjS2yNAbEG+Y0WWxq5/4w=="))
        let uuid = uuidBytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
        let vectors: [(String, RemoteXPCDictionary?)] = [
            ("empty dict", RemoteXPCDictionary()),
            ("no xpc body", nil),
            ("keys without padding", ["key": .string("value"), "key-key": .string("value")]),
            ("nested values", [
                "key1": .string("string-val"),
                "nested-dict": .dictionary([
                    "bool": .bool(true),
                    "int64": .int64(123),
                    "uint64": .uint64(321),
                    "data": .data(Data([0x1])),
                    "double": .double(1.2),
                ]),
            ]),
            ("null entry", ["null": .null]),
            ("dictionary with array", ["array": .array([.uint64(1), .uint64(2), .uint64(3)])]),
            ("encode uuid", ["uuidvalue": .uuid(uuid)]),
        ]
        for (name, body) in vectors {
            let encoded = try XPCWireCodec.encodeMessage(RemoteXPCMessage(flags: [.alwaysSet, .data], body: body))
            let decoded = try XPCWireCodec.decodeMessage(encoded)
            XCTAssertEqual(decoded.body, body, name)
            XCTAssertEqual(decoded.flags, [.alwaysSet, .data], name)
        }
    }

    func testUUIDIsWrittenInNetworkByteOrder() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "0102A304-0506-0708-090A-0B0C0D0E0F10"))
        var out: [UInt8] = []
        try XPCWireCodec.encodeObject(.uuid(uuid), into: &out)
        XCTAssertEqual(Hex.encode(Data(out)), "00a00000" + "0102a3040506070809" + "0a0b0c0d0e0f10")
    }

    func testRemainingTypesRoundTrip() throws {
        let body: RemoteXPCDictionary = [
            "date": .date(nanosecondsSince1970: 1_700_000_000_123_456_789),
            "negative": .int64(-42),
            "transfer": .fileTransfer(messageID: 7, transferSize: 4096),
            "unicode": .string("héllo ✋"),
            "data-3": .data(Data([1, 2, 3])),
            "mixed": .array([.null, .bool(false), .string("a"), .dictionary(["k": .double(-0.5)])]),
        ]
        let decoded = try XPCWireCodec.decodeMessage(
            try XPCWireCodec.encodeMessage(RemoteXPCMessage(flags: .alwaysSet, messageID: 99, body: body)))
        XCTAssertEqual(decoded.body, body)
        XCTAssertEqual(decoded.messageID, 99)
    }

    func testStringAndKeyPaddingAlignToFourBytes() throws {
        var out: [UInt8] = []
        try XPCWireCodec.encodeDictionary(["abc": .string("xyz")], into: &out)
        // type, length 20, count 1, "abc\0", string type, length 4, "xyz\0"
        XCTAssertEqual(Hex.encode(Data(out)),
                       "00f00000" + "14000000" + "01000000" + "61626300" + "00900000" + "04000000" + "78797a00")
    }

    func testBodylessMessageIsHeaderOnly() throws {
        let encoded = try XPCWireCodec.encodeMessage(
            RemoteXPCMessage(flags: [.alwaysSet, .initHandshake], messageID: 0, body: nil))
        XCTAssertEqual(Hex.encode(encoded), "920bb029" + "01004000" + "0000000000000000" + "0000000000000000")
        XCTAssertEqual(try XPCWireCodec.bodyLength(ofWrapper: encoded), 0)
    }

    func testDictionaryEqualityIgnoresOrderButEncodingKeepsIt() throws {
        let forward: RemoteXPCDictionary = ["a": .int64(1), "b": .int64(2)]
        let reverse: RemoteXPCDictionary = ["b": .int64(2), "a": .int64(1)]
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.keys, ["a", "b"])
        XCTAssertNotEqual(try XPCWireCodec.encodeMessage(RemoteXPCMessage(flags: .alwaysSet, body: forward)),
                          try XPCWireCodec.encodeMessage(RemoteXPCMessage(flags: .alwaysSet, body: reverse)))
    }

    func testSubscriptReplacesInPlaceAndRemoves() {
        var dictionary: RemoteXPCDictionary = ["a": .int64(1), "b": .int64(2)]
        dictionary["a"] = .int64(3)
        XCTAssertEqual(dictionary.keys, ["a", "b"])
        XCTAssertEqual(dictionary["a"], .int64(3))
        dictionary["a"] = nil
        XCTAssertEqual(dictionary.keys, ["b"])
    }
}
