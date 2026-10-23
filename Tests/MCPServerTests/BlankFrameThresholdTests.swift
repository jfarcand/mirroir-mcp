// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Checks the blank-frame thresholds on a near-black 500x252 mid-rotation frame vs. dark game splashes.
// ABOUTME: Runs the real Apple Vision OCR as the confirming pass, so a splash label must keep its vision call.

import CoreGraphics
import CoreText
import Foundation
import HelperLib
import ImageIO
import Testing
@testable import mirroir_mcp

@Suite("BlankFrameThresholds")
struct BlankFrameThresholdTests {

    /// The landscape mirroring frame seen mid-rotation in the field log.
    private static let frameSize = CGSize(width: 500, height: 252)
    /// Luminance of the near-black fill, as a 0-1 gray.
    private static let nearBlackGray: CGFloat = 0.03
    /// Per-pixel compression-style noise on the near-black fill, as a 0-1 gray.
    private static let noiseAmplitude: CGFloat = 0.01

    /// A near-black frame with deterministic speckle noise, optionally with a
    /// centred `label` drawn at `fontSize` in `textGray`.
    private func makeFrame(
        label: String? = nil, fontSize: CGFloat = 0, textGray: CGFloat = 1
    ) throws -> (image: CGImage, png: Data) {
        let width = Int(Self.frameSize.width)
        let height = Int(Self.frameSize.height)
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(gray: Self.nearBlackGray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = SplitMix64(seed: 7)
        for y in 0..<height {
            for x in stride(from: 0, to: width, by: 3) {
                let jitter = CGFloat(generator.next() % 1000) / 1000 * Self.noiseAmplitude
                ctx.setFillColor(CGColor(gray: Self.nearBlackGray + jitter, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        if let label {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: CGColor(gray: textGray, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: label, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, [])
            ctx.textPosition = CGPoint(
                x: (CGFloat(width) - bounds.width) / 2, y: CGFloat(height) / 2 - bounds.height / 2)
            CTLineDraw(line, ctx)
        }
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return (image, data as Data)
    }

    private func visionCalls(for png: Data) -> (calls: Int, blank: Bool) {
        let capture = SequenceCapture(frames: [png], windowSize: Self.frameSize)
        let counter = RequestCounter()
        let result = makeTestVisionDescriber(
            capture: capture, counter: counter, recognizer: AppleVisionTextRecognizer()
        ).describe(settleTimeoutUs: 0)
        return (counter.count, result?.screenBlank ?? false)
    }

    @Test("Near-black mid-rotation frame has no content samples and skips the vision call")
    func nearBlackRotationFrame() throws {
        let frame = try makeFrame()
        #expect(BlankFrameDetector.contentFraction(frame.image) == 0)
        #expect(BlankFrameDetector.isBlank(frame.image))
        let outcome = visionCalls(for: frame.png)
        #expect(outcome.calls == 0)
        #expect(outcome.blank)
    }

    @Test("Dark splash labels keep their vision call", arguments: [
        ("Tap to play", CGFloat(18), CGFloat(1)), ("Loading...", CGFloat(16), CGFloat(0.7)),
        ("Tap to play", CGFloat(12), CGFloat(1)), ("Loading...", CGFloat(10), CGFloat(0.7)),
    ])
    func darkSplash(label: String, fontSize: CGFloat, textGray: CGFloat) throws {
        let frame = try makeFrame(label: label, fontSize: fontSize, textGray: textGray)
        let fraction = try #require(BlankFrameDetector.contentFraction(frame.image))
        // Content is present but tiny: the sampled grid alone cannot be trusted
        // to keep this frame, which is why the local OCR pass confirms first.
        #expect(fraction > 0)
        #expect(fraction < 0.05)
        let outcome = visionCalls(for: frame.png)
        #expect(outcome.calls == 1, "'\(label)' (content fraction \(fraction)) must reach the vision model")
        #expect(!outcome.blank)
    }

    @Test("A 10pt splash label is pixel-blank: only the local OCR pass keeps its vision call")
    func pixelBlankSplashLabel() throws {
        let frame = try makeFrame(label: "Loading...", fontSize: 10, textGray: 0.7)
        #expect(BlankFrameDetector.isBlank(frame.image))
        let outcome = visionCalls(for: frame.png)
        #expect(outcome.calls == 1)
        #expect(!outcome.blank)
    }
}

/// Deterministic PRNG so the noise pattern is identical on every run.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
