/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Tests for AppleVisionTextRecognizer, the Apple Vision backend for TextRecognizing.
// ABOUTME: Validates empty-image handling, coordinate transforms, and content-bounds scaling.

import CoreGraphics
import CoreText
import Foundation
import HelperLib
import Testing
import Vision
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
    func testEmptyImageReturnsEmptyElements() throws {
        let image = makeBlankImage(width: 820, height: 1796)
        let windowSize = CGSize(width: 410, height: 898)
        let contentBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)

        let elements = try recognizer.recognizeText(
            in: image, windowSize: windowSize, contentBounds: contentBounds
        )

        #expect(elements.isEmpty)
    }

    @Test("Recognizes text from rendered image")
    func testRecognizesTextFromRenderedImage() throws {
        let image = makeImageWithText("Settings")
        let windowSize = CGSize(width: 410, height: 898)
        let contentBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)

        let elements = try recognizer.recognizeText(
            in: image, windowSize: windowSize, contentBounds: contentBounds
        )

        #expect(!elements.isEmpty)
        let found = elements.contains { $0.text == "Settings" }
        #expect(found, "Expected to find 'Settings' in recognized elements")
    }

    @Test("Coordinates are in window-point space")
    func testCoordinatesAreInWindowPointSpace() throws {
        let image = makeImageWithText("Hello")
        let windowSize = CGSize(width: 410, height: 898)
        let contentBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)

        let elements = try recognizer.recognizeText(
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

    @Test("Accurate is the default recognition level")
    func testAccurateIsDefault() throws {
        #expect(TimingConstants.ocrRecognitionLevel == "accurate")
    }

    @Test("Language correction is enabled by default")
    func testLanguageCorrectionIsDefault() throws {
        #expect(TimingConstants.ocrLanguageCorrection == true)
    }

    @Test("Fast recognition level returns results")
    func testFastRecognitionLevelReturnsResults() throws {
        // Use Vision's .fast recognition level directly to verify it
        // still detects large text — just possibly with fewer elements.
        let image = makeImageWithText("Settings", fontSize: 96)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try! handler.perform([request])

        let results = request.results ?? []
        #expect(!results.isEmpty, "Fast recognition should still detect large text")
        let found = results.contains { obs in
            obs.topCandidates(1).first?.string == "Settings"
        }
        #expect(found, "Expected to find 'Settings' with fast recognition")
    }

    @Test("Content bounds scaling adjusts coordinates")
    func testContentBoundsScaling() throws {
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
        let fullElements = try recognizer.recognizeText(
            in: image, windowSize: windowSize, contentBounds: fullBounds
        )

        // Reduced content bounds (simulates Larger display mode border)
        let reducedBounds = CGRect(x: 0, y: 0, width: 600, height: 1400)
        let scaledElements = try recognizer.recognizeText(
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

    @Test("Image taller than window maps Y coordinates through image height")
    func testImageTallerThanWindow() throws {
        // Simulate a screenshot taller than the window — screencapture may
        // include window chrome (rounded corners, home indicator area) beyond
        // the AX-reported window size.
        // Bug: github.com/jfarcand/mirroir-mcp/issues/11
        //
        // Window: 410x898 points. Image: 820x1880 pixels (backingScale=2.0).
        // imagePointHeight = 1880/2.0 = 940 points (> windowHeight of 898).
        // The old code mapped Vision coords to windowHeight, compressing
        // bottom-of-screen elements upward. The fix maps through imagePointHeight
        // so pixel positions convert correctly via the uniform backing scale.
        let imageHeight = 1880
        // Place text near the bottom of the image (roughly at image point y≈800)
        let textPixelY = 1600.0
        let image = makeImageWithText(
            "Profile",
            width: 820,
            height: imageHeight,
            fontSize: 48,
            position: CGPoint(x: 300, y: textPixelY)
        )
        let windowSize = CGSize(width: 410, height: 898)
        let contentBounds = CGRect(x: 0, y: 0, width: 820, height: imageHeight)

        let elements = try recognizer.recognizeText(
            in: image, windowSize: windowSize, contentBounds: contentBounds
        )

        guard let element = elements.first(where: { $0.text == "Profile" }) else {
            Issue.record("Expected to find 'Profile' element")
            return
        }

        // The backing scale is 820/410 = 2.0. Text drawn at pixel y=1600
        // should map to image-point y ≈ 1600/2.0 = 800 points.
        // With the old bug, it would map to y ≈ 800*(898/940) ≈ 764, compressed.
        let expectedY = textPixelY / 2.0
        let tolerance = 30.0
        #expect(abs(element.textTopY - expectedY) < tolerance,
                "Y should be near \(Int(expectedY)), got \(Int(element.textTopY))")

        // Coordinates can exceed windowHeight (elements in chrome area outside
        // the window), but elements inside the window should be accurate.
        #expect(element.textTopY >= 0,
                "Y coordinate should be non-negative")
    }

    @Test("Content bounds scaling still works for Larger display mode")
    func testContentBoundsScalingLargerMode() throws {
        // In Larger display mode, content is smaller than the image.
        // ContentBoundsDetector reports borders → scaling maps content to window.
        let image = makeImageWithText(
            "Scale",
            width: 820,
            height: 1796,
            position: CGPoint(x: 100, y: 400)
        )
        let windowSize = CGSize(width: 410, height: 898)

        // Full-image content bounds (no borders → no scaling)
        let fullBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)
        let fullElements = try recognizer.recognizeText(
            in: image, windowSize: windowSize, contentBounds: fullBounds
        )

        // Reduced content bounds (borders detected → scale to fill window)
        let reducedBounds = CGRect(x: 0, y: 0, width: 600, height: 1400)
        let scaledElements = try recognizer.recognizeText(
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

    @Test("OCR coordinates stay in bounds across macOS zoom modes")
    func testOCRCoordinatesAcrossZoomModes() throws {
        // macOS View menu zoom changes window size but backing scale stays ~2.0.
        // Verify OCR coordinates are within window bounds for all 3 modes.
        let zooms: [(imageW: Int, imageH: Int, winW: Double, winH: Double, name: String)] = [
            (840, 1880, 420, 940, "Larger"),
            (820, 1796, 410, 898, "Actual Size"),
            (700, 1540, 350, 770, "Smaller"),
        ]
        for z in zooms {
            let backingScale = Double(z.imageW) / z.winW
            #expect(abs(backingScale - 2.0) < 0.05,
                "\(z.name): backing scale \(backingScale) should be ~2.0")

            let image = makeImageWithText("Test",
                width: z.imageW, height: z.imageH,
                fontSize: 72,
                position: CGPoint(x: Double(z.imageW) / 4, y: Double(z.imageH) / 2))
            let windowSize = CGSize(width: z.winW, height: z.winH)
            let contentBounds = CGRect(x: 0, y: 0, width: z.imageW, height: z.imageH)

            let elements = try recognizer.recognizeText(
                in: image, windowSize: windowSize, contentBounds: contentBounds
            )
            for el in elements where el.text == "Test" {
                #expect(el.tapX >= 0 && el.tapX <= z.winW,
                    "\(z.name): tapX \(el.tapX) out of bounds for \(z.winW)pt window")
                #expect(el.textTopY >= 0,
                    "\(z.name): textTopY \(el.textTopY) should be non-negative")
            }
        }
    }
}
