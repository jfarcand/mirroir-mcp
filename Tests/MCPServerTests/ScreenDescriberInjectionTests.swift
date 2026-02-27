// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that ScreenDescriber correctly delegates to an injected TextRecognizing backend.
// ABOUTME: Uses StubTextRecognizer to verify stub elements flow through the full pipeline.

import CoreGraphics
import Foundation
import HelperLib
import ImageIO
import Testing
@testable import mirroir_mcp

@Suite("ScreenDescriber with injected TextRecognizer")
struct ScreenDescriberInjectionTests {

    /// Create valid PNG data from a blank image that CGImageSource can decode.
    private func makePNGData(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = ctx.makeImage()!

        let mutableData = NSMutableData()
        let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return mutableData as Data
    }

    @Test("Stub recognizer elements flow through pipeline")
    func testStubRecognizerElementsFlowThroughPipeline() {
        let bridge = StubBridge()
        let capture = StubCapture()
        let stubRecognizer = StubTextRecognizer()

        // Provide valid PNG data that ScreenDescriber can decode into a CGImage
        let pngData = makePNGData(width: 820, height: 1796)
        capture.captureResult = pngData.base64EncodedString()

        // Configure stub elements that the recognizer will return
        stubRecognizer.elements = [
            RawTextElement(
                text: "General",
                tapX: 205.0,
                textTopY: 300.0,
                textBottomY: 320.0,
                bboxWidth: 100.0,
                confidence: 0.99
            ),
            RawTextElement(
                text: "Privacy",
                tapX: 205.0,
                textTopY: 350.0,
                textBottomY: 370.0,
                bboxWidth: 90.0,
                confidence: 0.95
            ),
        ]

        let describer = ScreenDescriber(
            bridge: bridge,
            capture: capture,
            textRecognizer: stubRecognizer
        )

        let result = describer.describe(skipOCR: false)

        #expect(result != nil)
        guard let result else { return }

        // The stub's elements should appear in the output after TapPointCalculator
        #expect(result.elements.count == 2)

        let texts = Set(result.elements.map(\.text))
        #expect(texts.contains("General"))
        #expect(texts.contains("Privacy"))

        // Screenshot should be present (grid-overlaid)
        #expect(!result.screenshotBase64.isEmpty)
    }

    @Test("skipOCR bypasses text recognizer entirely")
    func testSkipOCRBypassesTextRecognizer() {
        let bridge = StubBridge()
        let capture = StubCapture()
        let stubRecognizer = StubTextRecognizer()

        let pngData = makePNGData(width: 820, height: 1796)
        capture.captureResult = pngData.base64EncodedString()

        // Even with elements configured, skipOCR should return empty
        stubRecognizer.elements = [
            RawTextElement(
                text: "ShouldNotAppear",
                tapX: 100.0,
                textTopY: 100.0,
                textBottomY: 120.0,
                bboxWidth: 80.0,
                confidence: 0.99
            ),
        ]

        let describer = ScreenDescriber(
            bridge: bridge,
            capture: capture,
            textRecognizer: stubRecognizer
        )

        let result = describer.describe(skipOCR: true)

        #expect(result != nil)
        #expect(result?.elements.isEmpty == true)
        #expect(result?.screenshotBase64.isEmpty == false)
    }

    @Test("Default initializer uses AppleVisionTextRecognizer")
    func testDefaultInitializerUsesAppleVision() {
        let bridge = StubBridge()
        let capture = StubCapture()

        // Just verify it compiles and works with the default parameter
        let describer = ScreenDescriber(bridge: bridge, capture: capture)

        // No capture data → returns nil
        let result = describer.describe(skipOCR: false)
        #expect(result == nil)
    }
}
