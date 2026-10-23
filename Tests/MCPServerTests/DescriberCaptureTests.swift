// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests settle policy (describer defaults, describe_screen default, settle_ms bounds) and the blank-frame vision skip.
// ABOUTME: Uses a frame-sequence capture double and a counting agent stub; no network, no real device.

import CoreGraphics
import Foundation
import HelperLib
import ImageIO
import XCTest
@testable import mirroir_mcp

final class DescriberCaptureTests: XCTestCase {

    private static let frameWidth = 205
    private static let frameHeight = 449

    /// PNG of a solid `gray` fill, optionally with white "label" bars drawn on it.
    private func makeFrame(gray: CGFloat, withContent: Bool) throws -> Data {
        let width = Self.frameWidth
        let height = Self.frameHeight
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if withContent {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            for row in 0..<6 {
                ctx.fill(CGRect(x: 20, y: 40 + row * 60, width: 160, height: 18))
            }
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    // MARK: - BlankFrameDetector

    func testSolidFramesAreBlank() throws {
        XCTAssertTrue(BlankFrameDetector.isBlank(pngData: try makeFrame(gray: 0, withContent: false)))
        XCTAssertTrue(BlankFrameDetector.isBlank(pngData: try makeFrame(gray: 1, withContent: false)))
    }

    func testFrameWithContentIsNotBlank() throws {
        XCTAssertFalse(BlankFrameDetector.isBlank(pngData: try makeFrame(gray: 0, withContent: true)))
    }

    func testUndecodableDataIsNotBlank() {
        XCTAssertFalse(BlankFrameDetector.isBlank(pngData: Data("not a png".utf8)))
    }

    // MARK: - Vision describer

    func testVisionBlankFrameSkipsTheAgent() throws {
        let capture = SequenceCapture(frames: [try makeFrame(gray: 0, withContent: false)])
        let counter = RequestCounter()
        let result = try XCTUnwrap(makeTestVisionDescriber(capture: capture, counter: counter).describe())

        XCTAssertTrue(result.screenBlank)
        XCTAssertTrue(result.elements.isEmpty)
        XCTAssertNil(result.visionUsage)
        XCTAssertEqual(counter.count, 0, "an OCR-confirmed blank frame must not cost a vision call")
    }

    func testVisionCallsTheAgentWhenLocalOCRFindsTextOnABlankLookingFrame() throws {
        // A dark splash with one short label samples as near-uniform; the local
        // OCR pass on the same frame is what proves it has content.
        let capture = SequenceCapture(frames: [try makeFrame(gray: 0, withContent: false)])
        let recognizer = StubTextRecognizer()
        recognizer.elements = [RawTextElement(
            text: "Tap to play", tapX: 100, textTopY: 200, textBottomY: 220,
            bboxWidth: 80, confidence: 0.9
        )]
        let counter = RequestCounter()
        let describer = makeTestVisionDescriber(
            capture: capture, counter: counter, recognizer: recognizer)
        let result = try XCTUnwrap(describer.describe())

        XCTAssertFalse(result.screenBlank)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(result.elements.map(\.text), ["Play"])
    }

    func testVisionCallsTheAgentWhenLocalOCRFails() throws {
        // A broken OCR engine is not evidence of an empty screen.
        let capture = SequenceCapture(frames: [try makeFrame(gray: 0, withContent: false)])
        let recognizer = StubTextRecognizer()
        recognizer.failure = TextRecognitionError.visionRequestFailed(underlying: CocoaError(.featureUnsupported))
        let counter = RequestCounter()
        _ = makeTestVisionDescriber(capture: capture, counter: counter, recognizer: recognizer)
            .describe()
        XCTAssertEqual(counter.count, 1)
    }

    func testVisionDescribesTheSettledFrameByDefault() throws {
        // Mid-rotation the first grab is black; the screen then draws and holds.
        let blank = try makeFrame(gray: 0, withContent: false)
        let drawn = try makeFrame(gray: 0, withContent: true)
        let capture = SequenceCapture(frames: [blank, drawn, drawn])
        let counter = RequestCounter()
        let result = try XCTUnwrap(makeTestVisionDescriber(capture: capture, counter: counter).describe())

        XCTAssertGreaterThanOrEqual(capture.callCount, 3, "vision must wait for two identical frames")
        XCTAssertFalse(result.screenBlank)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(result.elements.map(\.text), ["Play"])
    }

    func testVisionZeroSettleDescribesTheFirstFrame() throws {
        // A game scene never settles: settle 0 must not burn the settle window.
        let drawn = try makeFrame(gray: 0, withContent: true)
        let other = try makeFrame(gray: 0.3, withContent: true)
        let capture = SequenceCapture(frames: [drawn, other, drawn, other])
        let counter = RequestCounter()
        _ = try XCTUnwrap(makeTestVisionDescriber(capture: capture, counter: counter)
            .describe(settleTimeoutUs: 0))

        XCTAssertEqual(capture.callCount, 1)
        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - OCR describer

    func testOCRDescribesTheFirstFrameByDefault() throws {
        // OCR callers poll with their own delays; settling would only add latency.
        let first = try makeFrame(gray: 0.2, withContent: true)
        let settled = try makeFrame(gray: 0.5, withContent: true)
        let capture = SequenceCapture(frames: [first, settled, settled])
        let describer = ScreenDescriber(
            bridge: StubBridge(), capture: capture, textRecognizer: StubTextRecognizer()
        )

        XCTAssertNotNil(describer.describe())
        XCTAssertEqual(capture.callCount, 1)
    }

    func testOCRSettlesWhenAskedTo() throws {
        let first = try makeFrame(gray: 0.2, withContent: true)
        let settled = try makeFrame(gray: 0.5, withContent: true)
        let capture = SequenceCapture(frames: [first, settled, settled])
        let describer = ScreenDescriber(
            bridge: StubBridge(), capture: capture, textRecognizer: StubTextRecognizer()
        )

        XCTAssertNotNil(describer.describe(settleTimeoutUs: EnvConfig.frameSettleTimeoutUs))
        XCTAssertGreaterThanOrEqual(capture.callCount, 3, "an explicit settle waits for two identical frames")
    }

    func testOCRFlagsAnEmptyBlankFrame() throws {
        let capture = SequenceCapture(frames: [try makeFrame(gray: 0, withContent: false)])
        let describer = ScreenDescriber(
            bridge: StubBridge(), capture: capture, textRecognizer: StubTextRecognizer()
        )
        let result = try XCTUnwrap(describer.describe())
        XCTAssertTrue(result.screenBlank)
    }

    func testOCRDoesNotFlagABlankFrameThatYieldedText() throws {
        let capture = SequenceCapture(frames: [try makeFrame(gray: 0, withContent: false)])
        let recognizer = StubTextRecognizer()
        recognizer.elements = [RawTextElement(
            text: "Loading", tapX: 100, textTopY: 200, textBottomY: 220,
            bboxWidth: 80, confidence: 0.9
        )]
        let describer = ScreenDescriber(
            bridge: StubBridge(), capture: capture, textRecognizer: recognizer
        )
        let result = try XCTUnwrap(describer.describe())
        XCTAssertFalse(result.screenBlank)
    }

    // MARK: - Settle window bounds

    func testZeroSettleCapturesOnceWithoutPolling() throws {
        let capture = SequenceCapture(frames: [
            try makeFrame(gray: 0.2, withContent: true), try makeFrame(gray: 0.5, withContent: true),
        ])
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertNotNil(capture.captureSettledWithInfo(timeoutUs: 0))
        let elapsedUs = (DispatchTime.now().uptimeNanoseconds - start) / UInt64(NSEC_PER_USEC)

        XCTAssertEqual(capture.callCount, 1)
        XCTAssertLessThan(elapsedUs, UInt64(EnvConfig.frameSettlePollUs), "0 must not wait a poll interval")
    }

    func testSettleMsClampsEveryExtreme() {
        let capMs = EnvConfig.frameSettleMaxTimeoutUs / 1000
        let capUs = capMs * 1000
        let cases: [(JSONValue, UInt32)] = [
            (.number(-5), 0),
            (.number(Double(Int.min)), 0),
            (.number(0), 0),
            (.number(250), 250_000),
            (.number(Double(capMs)), capUs),
            (.number(4_294_968), capUs),
            // Double(Int.max) rounds up to 2^63, past Int; this is the largest
            // JSON number below it, so asInt() yields an Int near Int.max.
            (.number(Double(Int.max).nextDown), capUs),
        ]
        XCTAssertEqual(MirroirMCP.settleTimeoutUs(from: ["settle_ms": .number(Double(Int.max))]), nil,
            "2^63 does not fit an Int and is not a settle window")
        for (value, expected) in cases {
            XCTAssertEqual(MirroirMCP.settleTimeoutUs(from: ["settle_ms": value]), expected, "\(value)")
        }
        XCTAssertNil(MirroirMCP.settleTimeoutUs(from: [:]))
        XCTAssertNil(MirroirMCP.settleTimeoutUs(from: ["settle_ms": .number(1e300)]),
            "a value no Int can hold is not a settle window")
    }

    // MARK: - describe_screen settle policy

    /// Run describe_screen against `describer` and return how many frames it captured.
    private func describeScreenCaptures(
        describer: any ScreenDescribing, capture: SequenceCapture, args: [String: JSONValue]
    ) throws -> Int {
        let ctx = TargetContext(
            name: "iphone", targetType: "iphone-mirroring", bundleID: nil,
            bridge: StubBridge(), input: StubInput(), capture: capture,
            describer: describer, ocrDescriber: describer, recorder: StubRecorder(),
            capabilities: [.menuActions, .spotlight, .home, .appSwitcher]
        )
        let registry = TargetRegistry(targets: ["iphone": ctx], defaultName: "iphone")
        let server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil))
        MirroirMCP.registerScreenTools(server: server, registry: registry)
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string("describe_screen"), "arguments": .object(args)])
        )
        _ = try XCTUnwrap(server.handleRequest(request))
        return capture.callCount
    }

    /// A lagged first frame, then the settled screen.
    private func laggedSequence() throws -> SequenceCapture {
        let settled = try makeFrame(gray: 0.5, withContent: true)
        return SequenceCapture(frames: [try makeFrame(gray: 0.2, withContent: true), settled, settled])
    }

    func testDescribeScreenSettlesByDefaultInOCRMode() throws {
        let capture = try laggedSequence()
        let ocr = ScreenDescriber(bridge: StubBridge(), capture: capture, textRecognizer: StubTextRecognizer())
        XCTAssertGreaterThanOrEqual(try describeScreenCaptures(describer: ocr, capture: capture, args: [:]), 3,
            "a client describe after an action must not read the lagged pre-action frame")

        let optOut = try laggedSequence()
        let fast = ScreenDescriber(bridge: StubBridge(), capture: optOut, textRecognizer: StubTextRecognizer())
        XCTAssertEqual(try describeScreenCaptures(
            describer: fast, capture: optOut, args: ["settle_ms": .number(0)]), 1)
    }

    func testDescribeScreenSettlesByDefaultInVisionMode() throws {
        let capture = try laggedSequence()
        let vision = makeTestVisionDescriber(capture: capture, counter: RequestCounter())
        XCTAssertGreaterThanOrEqual(try describeScreenCaptures(describer: vision, capture: capture, args: [:]), 3)

        let optOut = try laggedSequence()
        let fast = makeTestVisionDescriber(capture: optOut, counter: RequestCounter())
        XCTAssertEqual(try describeScreenCaptures(
            describer: fast, capture: optOut, args: ["settle_ms": .number(0)]), 1)
    }
}
