// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Display-stream tests: the media blob pinned to go-ios's captured offer, the plist envelope, zlib level.
// ABOUTME: Also pins the startmediastream / stopmediastream request payload shapes.

import Foundation
import XCTest
import zlib
@testable import MirroirCoreDevice

final class DisplayStreamOfferTests: XCTestCase {
    /// go-ios offer_test.go `capturedVideoMediaBlobHex`: the uncompressed blob
    /// of an offer Xcode sent, with `capturedVideoSessionID`.
    static let capturedVideoMediaBlobHex = "080110012a7f088182bae90810001a3f087b120a0801100118c387032000120a"
        + "0801100218c387032000120a0801100118c387032000120a0801100218c38703"
        + "20001a09464c533b53573a313b20011a2e0864120a0801100118c38703200012"
        + "0a0801100218c3870320001a10464c533b565241453a303b53573a313b200e38"
        + "01403f6001320d56696365726f7920312e372e3040004a0908ea1f1000188080"
        + "014a0b080010c0d1e123188080204a0a08001080b489131880604a0508101084"
        + "204a0b08001080dac409188080064a05080410e4324a0b080010809bee021880"
        + "80084a0b08001080c2d72f188080404a0b080010808ece1c188080104a050801"
        + "10ab026880c0dd87d2a0c0e9ed017002800100900101"
    static let capturedVideoSessionID: UInt32 = 2_368_635_137

    /// go-ios TestBuildVideoMediaBlobMatchesCapture: the capture had LTRP on
    /// and FEC off, the inverse of the defaults.
    func testMediaBlobMatchesCapture() {
        var parameters = DisplayStreamOffer.VideoBlobParameters(sessionID: Self.capturedVideoSessionID)
        parameters.longTermReferenceFrames = true
        parameters.forwardErrorCorrection = false
        XCTAssertEqual(Hex.encode(DisplayStreamOffer.videoMediaBlob(parameters)), Self.capturedVideoMediaBlobHex)
    }

    /// go-ios TestVarintPadded.
    func testPaddedVarint() {
        let vectors: [(UInt64, Int, String)] = [
            (0, 5, "8080808000"),
            (1, 3, "818000"),
            (300, 2, "ac02"),
            (UInt64(Self.capturedVideoSessionID), 5, "8182bae908"),
        ]
        for (value, width, expected) in vectors {
            let padded = Protobuf.paddedVarint(value, width: width)
            XCTAssertEqual(padded.count, width)
            XCTAssertEqual(Hex.encode(Data(padded)), expected)
        }
    }

    /// go-ios TestVarintPaddedIsValueStable: padding never changes the value.
    func testPaddedVarintDecodesToTheSameValue() {
        for value: UInt64 in [0, 1, 127, 128, 300, UInt64(Self.capturedVideoSessionID)] {
            let padded = Protobuf.paddedVarint(value, width: 5)
            var decoded: UInt64 = 0
            for (index, byte) in padded.enumerated() {
                decoded |= UInt64(byte & 0x7F) << (7 * UInt64(index))
            }
            XCTAssertEqual(decoded, value)
            XCTAssertEqual(padded.last.map { $0 & 0x80 }, 0, "last byte ends the varint")
        }
    }

    /// go-ios TestBuildVideoNegotiatorOfferEnvelope.
    func testOfferEnvelope() throws {
        let callID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let offer = try DisplayStreamOffer.videoNegotiatorOffer(callID: callID, sessionID: Self.capturedVideoSessionID)
        XCTAssertEqual(offer.prefix(8), Data("bplist00".utf8))
        let decoded = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: offer, format: nil) as? [String: Any])

        XCTAssertEqual(decoded["avcMediaStreamNegotiatorMode"] as? Int, DisplayStreamOffer.negotiatorModeVideo)
        XCTAssertEqual(decoded["avcMediaStreamOptionCallID"] as? String, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(decoded["avcMediaStreamOptionRemoteEndpointInfo"] as? Data,
                       DisplayStreamOffer.remoteEndpointInfo())
        let blob = try XCTUnwrap(decoded["avcMediaStreamNegotiatorMediaBlob"] as? Data)
        XCTAssertEqual(try inflate(blob), DisplayStreamOffer.videoMediaBlob(
            DisplayStreamOffer.VideoBlobParameters(sessionID: Self.capturedVideoSessionID)))
    }

    /// The zlib header must advertise level 9 (FLEVEL 3): 0x78 0xDA, which is
    /// what Go's zlib.BestCompression writes too. The deflate bytes after it
    /// come from libz rather than Go's compressor, so only the header and the
    /// inflated content are comparable with go-ios.
    func testCompressionIsZlibAtBestLevel() throws {
        let blob = DisplayStreamOffer.videoMediaBlob(DisplayStreamOffer.VideoBlobParameters(sessionID: 1))
        let compressed = try DisplayStreamOffer.compress(blob)
        XCTAssertEqual(Array(compressed.prefix(2)), [0x78, 0xDA])
        XCTAssertEqual(try inflate(compressed), blob)
    }

    func testRemoteEndpointInfoCarriesHostIdentity() {
        let info = String(decoding: DisplayStreamOffer.remoteEndpointInfo(), as: UTF8.self)
        XCTAssertTrue(info.contains(DisplayStreamOffer.hostModel))
        XCTAssertTrue(info.contains(DisplayStreamOffer.hostOSVersion))
        XCTAssertTrue(info.contains(DisplayStreamOffer.hostBuild))
    }

    // MARK: - Requests

    func testStartVideoStreamRequestShape() throws {
        let session = UUID()
        let request = try DisplayServiceRequests.startVideoStream(
            VideoStreamRequest(receiverIP: "fd00::2", receiverPort: 5000, senderIP: "fd00::1"),
            offer: Data([1, 2]), clientSessionID: session, deviceIdentifier: "dev")
        XCTAssertEqual(request["CoreDevice.featureIdentifier"], .string(DisplayServiceRequests.featureStartMediaStream))
        XCTAssertEqual(request["CoreDevice.actionIdentifier"], .string(DisplayServiceRequests.actionMediaStreamStart))
        XCTAssertEqual(request["CoreDevice.CoreDeviceDDIProtocolVersion"], .int64(2))
        let input = try XCTUnwrap(request["CoreDevice.input"]?.dictionaryValue)
        XCTAssertEqual(input["receiverPort"], .uint64(5000))
        XCTAssertEqual(input["timeout"], .uint64(10))
        XCTAssertEqual(input["clientSupportedFeatures"], .uint64(140))
        XCTAssertEqual(input["negotiatorOffer"], .data(Data([1, 2])))
        let options = try XCTUnwrap(input["options"]?.dictionaryValue)
        XCTAssertEqual(options["VideoStreamForDisplayID"], .dictionary(["int": .int64(1)]))
        XCTAssertEqual(options["avcMediaStreamOptionClientSessionID"], .dictionary(["uuid": .uuid(session)]))
        _ = try XPCWireCodec.encodeMessage(RemoteXPCMessage(flags: .alwaysSet, body: request))
    }

    /// go-ios TestStartVideoStreamRequiresAReceiver.
    func testStartVideoStreamRequiresAddresses() {
        XCTAssertThrowsError(try DisplayServiceRequests.startVideoStream(
            VideoStreamRequest(receiverIP: "", receiverPort: 0, senderIP: "fd00::1"),
            offer: Data(), clientSessionID: UUID(), deviceIdentifier: "d"))
        XCTAssertThrowsError(try DisplayServiceRequests.startVideoStream(
            VideoStreamRequest(receiverIP: "fd00::2", receiverPort: 5000, senderIP: ""),
            offer: Data(), clientSessionID: UUID(), deviceIdentifier: "d")) { error in
            XCTAssertEqual(error as? DisplayStreamError, .missingAddress(field: "senderIP"))
        }
    }

    /// go-ios TestStopMediaStreamSendsStopAll.
    func testStopMediaStreamCarriesStopAll() throws {
        let request = DisplayServiceRequests.stopMediaStream(clientSessionID: UUID(), deviceIdentifier: "dev")
        XCTAssertEqual(request["CoreDevice.actionIdentifier"], .string(DisplayServiceRequests.actionMediaStreamStop))
        let input = try XCTUnwrap(request["CoreDevice.input"]?.dictionaryValue)
        XCTAssertEqual(input["stopAll"], .bool(true))
        XCTAssertNotNil(input["avcMediaStreamOptionClientSessionID"])
    }

    private func inflate(_ data: Data) throws -> Data {
        var source = [UInt8](data)
        let capacity = 64 * 1024
        var destination = [UInt8](repeating: 0, count: capacity)
        var destinationLength = uLong(capacity)
        let status = uncompress(&destination, &destinationLength, &source, uLong(source.count))
        XCTAssertEqual(status, Z_OK)
        return Data(destination.prefix(Int(destinationLength)))
    }
}
