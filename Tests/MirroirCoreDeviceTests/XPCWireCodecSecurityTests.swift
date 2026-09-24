// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Bounds-checking tests for the XPC decoder: malformed, truncated and hostile input must throw, never trap.
// ABOUTME: Ports go-ios ios/xpc/encoding_security_test.go and adds a truncation sweep and a nesting bomb.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation
import XCTest
@testable import MirroirCoreDevice

final class XPCWireCodecSecurityTests: XCTestCase {
    private let int64Type: UInt32 = 0x3000
    private let stringType: UInt32 = 0x9000
    private let arrayType: UInt32 = 0xE000
    private let dictionaryType: UInt32 = 0xF000

    /// Frames a raw top-level object into a complete message whose body length
    /// matches the bytes present (go-ios `buildMessage`).
    private func message(body object: [UInt8], declaredLength: UInt64? = nil) -> Data {
        var out: [UInt8] = []
        out.appendUInt32LE(XPCWireCodec.wrapperMagic)
        out.appendUInt32LE(RemoteXPCMessageFlags.alwaysSet.rawValue)
        out.appendUInt64LE(declaredLength ?? UInt64(object.count + XPCWireCodec.bodyHeaderLength))
        out.appendUInt64LE(0)
        out.appendUInt32LE(XPCWireCodec.objectMagic)
        out.appendUInt32LE(XPCWireCodec.bodyVersion)
        return Data(out + object)
    }

    /// go-ios HIGH-7: a body length below the 8-byte body header must not underflow.
    func testBodyLengthBelowHeaderSizeIsRejected() {
        XCTAssertThrowsError(try XPCWireCodec.decodeMessage(message(body: [], declaredLength: 4))) { error in
            XCTAssertEqual(error as? XPCCodecError, .bodyLengthTooSmall(4))
        }
    }

    /// go-ios HIGH-8: a non-dictionary top-level object is an error, not a crash.
    func testNonDictionaryTopLevelIsRejected() {
        var body: [UInt8] = []
        body.appendUInt32LE(int64Type)
        body.appendUInt64LE(42)
        XCTAssertThrowsError(try XPCWireCodec.decodeMessage(message(body: body))) { error in
            XCTAssertEqual(error as? XPCCodecError, .topLevelNotDictionary)
        }
    }

    /// go-ios MED-1 (string): a ~4 GiB claimed string over 2 real bytes.
    func testOversizedStringLengthIsRejected() {
        var body: [UInt8] = []
        body.appendUInt32LE(stringType)
        body.appendUInt32LE(0xFFFF_FFF0)
        body.append(contentsOf: [0x41, 0x00])
        XCTAssertThrowsError(try XPCWireCodec.decodeMessage(message(body: body))) { error in
            guard case .lengthExceedsRemaining(let field, _, _)? = error as? XPCCodecError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(field, "string")
        }
    }

    /// go-ios MED-1 (array): ~2 billion entries claimed, none present.
    func testOversizedArrayCountIsRejectedBeforeAllocating() {
        var body: [UInt8] = []
        body.appendUInt32LE(arrayType)
        body.appendUInt32LE(0)
        body.appendUInt32LE(0x7FFF_FFFF)
        XCTAssertThrowsError(try XPCWireCodec.decodeMessage(message(body: body))) { error in
            XCTAssertEqual(error as? XPCCodecError,
                           .entryCountExceedsRemaining(container: "array", count: 0x7FFF_FFFF, remaining: 0))
        }
    }

    /// go-ios MED-1 (dictionary): ~2 billion entries claimed, none present.
    func testOversizedDictionaryCountIsRejectedBeforeLooping() {
        var body: [UInt8] = []
        body.appendUInt32LE(dictionaryType)
        body.appendUInt32LE(0)
        body.appendUInt32LE(0x7FFF_FFFF)
        XCTAssertThrowsError(try XPCWireCodec.decodeMessage(message(body: body))) { error in
            XCTAssertEqual(error as? XPCCodecError,
                           .entryCountExceedsRemaining(container: "dictionary", count: 0x7FFF_FFFF, remaining: 0))
        }
    }

    func testBodyLengthAboveCapIsRejectedFromTheWrapperAlone() {
        var header: [UInt8] = []
        header.appendUInt32LE(XPCWireCodec.wrapperMagic)
        header.appendUInt32LE(0)
        header.appendUInt64LE(UInt64.max)
        header.appendUInt64LE(0)
        XCTAssertThrowsError(try XPCWireCodec.bodyLength(ofWrapper: Data(header))) { error in
            XCTAssertEqual(error as? XPCCodecError,
                           .bodyLengthTooLarge(declared: UInt64.max, limit: XPCWireCodec.maximumBodyLength))
        }
    }

    func testWrongMagicsAndVersionAreRejected() throws {
        var bytes = [UInt8](try Fixture.data("xpc_empty_dict", "bin"))
        var wrongWrapper = bytes
        wrongWrapper[0] ^= 0xFF
        XCTAssertThrowsError(try XPCWireCodec.decodeMessage(Data(wrongWrapper)))
        let objectMagicOffset = XPCWireCodec.wrapperHeaderLength
        bytes[objectMagicOffset] ^= 0xFF
        XCTAssertThrowsError(try XPCWireCodec.decodeMessage(Data(bytes)))
    }

    func testUnknownTypeTagIsRejected() {
        var body: [UInt8] = []
        body.appendUInt32LE(dictionaryType)
        body.appendUInt32LE(12)
        body.appendUInt32LE(1)
        body.append(contentsOf: Array("k".utf8) + [0, 0, 0])
        body.appendUInt32LE(0xDEAD_0000)
        XCTAssertThrowsError(try XPCWireCodec.decodeMessage(message(body: body))) { error in
            XCTAssertEqual(error as? XPCCodecError, .unknownType(0xDEAD_0000))
        }
    }

    func testUnterminatedKeyIsRejected() {
        var body: [UInt8] = []
        body.appendUInt32LE(dictionaryType)
        body.appendUInt32LE(8)
        body.appendUInt32LE(1)
        body.append(contentsOf: Array("abcd".utf8))
        XCTAssertThrowsError(try XPCWireCodec.decodeMessage(message(body: body)))
    }

    /// Every strict prefix of a real message must throw: no truncation point
    /// may read out of bounds or return a partial message.
    func testEveryTruncationOfTheCaptureThrows() throws {
        let bytes = try Fixture.data("xpc_dict", "bin")
        for length in 0..<bytes.count {
            XCTAssertThrowsError(try XPCWireCodec.decodeMessage(bytes.prefix(length)), "prefix \(length)")
        }
    }

    /// Flipping any single byte either decodes or throws; it never traps.
    func testSingleByteCorruptionNeverTraps() throws {
        let bytes = [UInt8](try Fixture.data("xpc_dict", "bin"))
        for index in bytes.indices {
            var corrupted = bytes
            corrupted[index] ^= 0xFF
            _ = try? XPCWireCodec.decodeMessage(Data(corrupted))
        }
    }

    /// Nested arrays deeper than the limit are refused instead of recursing
    /// until the stack overflows.
    func testNestingBombIsRejected() {
        let depth = XPCWireCodec.maximumNestingDepth + 2
        var object: [UInt8] = []
        object.appendUInt32LE(0x1000)
        for _ in 0..<depth {
            var wrapped: [UInt8] = []
            wrapped.appendUInt32LE(arrayType)
            wrapped.appendUInt32LE(UInt32(object.count + 4))
            wrapped.appendUInt32LE(1)
            object = wrapped + object
        }
        var body: [UInt8] = []
        body.appendUInt32LE(dictionaryType)
        body.appendUInt32LE(UInt32(object.count + 8))
        body.appendUInt32LE(1)
        body.append(contentsOf: Array("k".utf8) + [0, 0, 0])
        body.append(contentsOf: object)
        XCTAssertThrowsError(try XPCWireCodec.decodeMessage(message(body: body))) { error in
            XCTAssertEqual(error as? XPCCodecError, .nestingTooDeep(limit: XPCWireCodec.maximumNestingDepth))
        }
    }
}
