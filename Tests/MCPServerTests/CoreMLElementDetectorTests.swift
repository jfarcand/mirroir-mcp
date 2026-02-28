// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for CoreMLElementDetector's coordinate transform and filtering logic.
// ABOUTME: Uses the extracted static convertBoundingBox method to avoid needing a real model.

import CoreGraphics
import Foundation
import HelperLib
import Testing
@testable import mirroir_mcp

@Suite("CoreMLElementDetector")
struct CoreMLElementDetectorTests {

    // MARK: - Coordinate Transform Tests

    @Test("Coordinate transform matches Vision's transform for same input")
    func testCoordinateTransformMatchesVision() {
        // A bounding box centered at (0.5, 0.5) with width 0.2, height 0.05
        // should produce the same coordinates as AppleVisionTextRecognizer
        // for the same input parameters.
        let bbox = CGRect(x: 0.4, y: 0.475, width: 0.2, height: 0.05)
        let windowSize = CGSize(width: 410, height: 898)
        let contentBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)

        let element = CoreMLElementDetector.convertBoundingBox(
            bbox: bbox,
            label: "Button",
            confidence: 0.95,
            windowSize: windowSize,
            contentBounds: contentBounds,
            imageWidth: 820
        )

        // tapX should be at the horizontal center of the window
        #expect(element.text == "Button")
        #expect(element.tapX > 0 && element.tapX <= Double(windowSize.width))
        #expect(element.textTopY >= 0 && element.textTopY <= Double(windowSize.height))
        #expect(element.textBottomY >= 0 && element.textBottomY <= Double(windowSize.height))
        #expect(element.textTopY < element.textBottomY, "Top should be above bottom")
        #expect(element.bboxWidth > 0)
        #expect(element.confidence == 0.95)

        // For a centered bbox (midX=0.5) with no content offset, tapX should be ~205
        #expect(abs(element.tapX - 205.0) < 1.0, "Center bbox should map to center of window")
    }

    @Test("Bounding box at top-left corner maps correctly")
    func testTopLeftCorner() {
        // bbox at top-left in Vision coords: origin=(0,0.9), size=(0.1,0.1)
        // Vision origin is bottom-left, so high Y = top of screen
        let bbox = CGRect(x: 0.0, y: 0.9, width: 0.1, height: 0.1)
        let windowSize = CGSize(width: 410, height: 898)
        let contentBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)

        let element = CoreMLElementDetector.convertBoundingBox(
            bbox: bbox,
            label: "Icon",
            confidence: 0.8,
            windowSize: windowSize,
            contentBounds: contentBounds,
            imageWidth: 820
        )

        // Top-left of screen: small tapX, small textTopY
        #expect(element.tapX < Double(windowSize.width) / 2)
        #expect(element.textTopY < Double(windowSize.height) / 4)
    }

    @Test("Content bounds scaling adjusts coordinates outward")
    func testContentBoundsScaling() {
        let bbox = CGRect(x: 0.3, y: 0.4, width: 0.2, height: 0.1)
        let windowSize = CGSize(width: 410, height: 898)

        let fullBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)
        let fullElement = CoreMLElementDetector.convertBoundingBox(
            bbox: bbox, label: "A", confidence: 0.9,
            windowSize: windowSize, contentBounds: fullBounds, imageWidth: 820
        )

        // Reduced content bounds (simulates Larger display mode)
        let reducedBounds = CGRect(x: 0, y: 0, width: 600, height: 1400)
        let scaledElement = CoreMLElementDetector.convertBoundingBox(
            bbox: bbox, label: "A", confidence: 0.9,
            windowSize: windowSize, contentBounds: reducedBounds, imageWidth: 820
        )

        // With reduced content bounds, coordinates should be scaled outward
        #expect(scaledElement.tapX > fullElement.tapX,
                "Scaled X should be larger than full-bounds X")
        #expect(scaledElement.bboxWidth > fullElement.bboxWidth,
                "Scaled bbox width should be larger than full-bounds width")
    }

    @Test("Label text is passed through as element text")
    func testLabelPassthrough() {
        let bbox = CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.05)
        let windowSize = CGSize(width: 410, height: 898)
        let contentBounds = CGRect(x: 0, y: 0, width: 820, height: 1796)

        let element = CoreMLElementDetector.convertBoundingBox(
            bbox: bbox, label: "TextField", confidence: 0.75,
            windowSize: windowSize, contentBounds: contentBounds, imageWidth: 820
        )

        #expect(element.text == "TextField")
        #expect(element.confidence == 0.75)
    }

    // MARK: - Model Loading Error Tests

    @Test("Missing model returns empty results")
    func testMissingModelReturnsEmpty() {
        let nonexistentURL = URL(fileURLWithPath: "/tmp/nonexistent-model.mlmodelc")
        let detector = CoreMLElementDetector(
            modelURL: nonexistentURL,
            confidenceThreshold: 0.3
        )

        // Create a minimal 1x1 image for the test
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = ctx.makeImage()!

        let results = detector.recognizeText(
            in: image,
            windowSize: CGSize(width: 410, height: 898),
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1)
        )

        #expect(results.isEmpty, "Should return empty for non-existent model")
    }

    @Test("Invalid model path returns empty results")
    func testInvalidModelReturnsEmpty() {
        // Point to an existing but non-model file
        let invalidURL = URL(fileURLWithPath: "/tmp")
        let detector = CoreMLElementDetector(
            modelURL: invalidURL,
            confidenceThreshold: 0.3
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = ctx.makeImage()!

        let results = detector.recognizeText(
            in: image,
            windowSize: CGSize(width: 410, height: 898),
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1)
        )

        #expect(results.isEmpty, "Should return empty for invalid model")
    }
}
