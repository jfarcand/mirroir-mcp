// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AppleVisionTextRecognizer, the Apple Vision backend for TextRecognizing.
// ABOUTME: Validates empty-image handling, coordinate transforms, and content-bounds scaling.

import CoreGraphics
import CoreText
import Foundation
import HelperLib
import Testing
@testable import mirroir_mcp

@Suite("AppleVisionTextRecognizer")
struct AppleVisionTextRecognizerTests {

    let recognizer = AppleVisionTextRecognizer()

    /// Create a blank white CGImage for testing.
    private func makeBlankImage(width: Int, height: Int) -> CGImage {
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
        return ctx.makeImage()!
    }

    /// Create a CGImage with large black text drawn on a white background.
    /// Vision's OCR needs reasonably large text to detect it reliably.
    private func makeImageWithText(
        _ text: String,
        width: Int = 820,
        height: Int = 1796,
        fontSize: CGFloat = 72,
        position: CGPoint = CGPoint(x: 200, y: 800)
    ) -> CGImage {
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
        // White background
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw text using Core Text
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1])!,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)

        // CGContext origin is bottom-left; position.y is from top, so flip
        let flippedY = CGFloat(height) - position.y
        ctx.textPosition = CGPoint(x: position.x, y: flippedY)
        CTLineDraw(line, ctx)

        return ctx.makeImage()!
    }

    @Test("Empty image returns empty elements")
    func testEmptyImageReturnsEmptyElements() {
        let image = makeBlankImage(width: 820, height: 1796)
        let windowSize = CGSize(width: 410, height: 898)
        let contentBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)

        let elements = recognizer.recognizeText(
            in: image, windowSize: windowSize, contentBounds: contentBounds
        )

        #expect(elements.isEmpty)
    }

    @Test("Recognizes text from rendered image")
    func testRecognizesTextFromRenderedImage() {
        let image = makeImageWithText("Settings")
        let windowSize = CGSize(width: 410, height: 898)
        let contentBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)

        let elements = recognizer.recognizeText(
            in: image, windowSize: windowSize, contentBounds: contentBounds
        )

        #expect(!elements.isEmpty)
        let found = elements.contains { $0.text == "Settings" }
        #expect(found, "Expected to find 'Settings' in recognized elements")
    }

    @Test("Coordinates are in window-point space")
    func testCoordinatesAreInWindowPointSpace() {
        let image = makeImageWithText("Hello")
        let windowSize = CGSize(width: 410, height: 898)
        let contentBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)

        let elements = recognizer.recognizeText(
            in: image, windowSize: windowSize, contentBounds: contentBounds
        )

        guard let element = elements.first(where: { $0.text == "Hello" }) else {
            Issue.record("Expected to find 'Hello' element")
            return
        }

        // Coordinates should be within the window bounds
        #expect(element.tapX >= 0 && element.tapX <= Double(windowSize.width))
        #expect(element.textTopY >= 0 && element.textTopY <= Double(windowSize.height))
        #expect(element.textBottomY >= 0 && element.textBottomY <= Double(windowSize.height))
        #expect(element.textTopY < element.textBottomY, "Top should be above bottom in window coordinates")
        #expect(element.bboxWidth > 0)
        #expect(element.confidence > 0)
    }

    @Test("Content bounds scaling adjusts coordinates")
    func testContentBoundsScaling() {
        // Simulate "Larger" display mode: image is 820x1796 pixels but
        // content only occupies the top-left 600x1400 pixels.
        let image = makeImageWithText(
            "Scale",
            width: 820,
            height: 1796,
            position: CGPoint(x: 100, y: 400)
        )
        let windowSize = CGSize(width: 410, height: 898)

        // Full-window content bounds (no scaling)
        let fullBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)
        let fullElements = recognizer.recognizeText(
            in: image, windowSize: windowSize, contentBounds: fullBounds
        )

        // Reduced content bounds (simulates Larger display mode border)
        let reducedBounds = CGRect(x: 0, y: 0, width: 600, height: 1400)
        let scaledElements = recognizer.recognizeText(
            in: image, windowSize: windowSize, contentBounds: reducedBounds
        )

        guard let fullEl = fullElements.first(where: { $0.text == "Scale" }),
              let scaledEl = scaledElements.first(where: { $0.text == "Scale" })
        else {
            Issue.record("Expected to find 'Scale' in both element sets")
            return
        }

        // With reduced content bounds, coordinates should be scaled outward
        // (larger values) to map the smaller content area to the full window.
        #expect(scaledEl.tapX > fullEl.tapX,
                "Scaled X should be larger than full-bounds X")
        #expect(scaledEl.bboxWidth > fullEl.bboxWidth,
                "Scaled bbox width should be larger than full-bounds width")
    }
}
