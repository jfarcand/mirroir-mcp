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
            mapping: WindowPointMapping(
                imageWidth: 820, imageHeight: 1796, windowSize: windowSize, contentBounds: contentBounds)
        )!

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
            mapping: WindowPointMapping(
                imageWidth: 820, imageHeight: 1796, windowSize: windowSize, contentBounds: contentBounds)
        )!

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
            mapping: WindowPointMapping(
            imageWidth: 820, imageHeight: 1796, windowSize: windowSize, contentBounds: fullBounds)
        )!

        // Reduced content bounds (simulates Larger display mode)
        let reducedBounds = CGRect(x: 0, y: 0, width: 600, height: 1400)
        let scaledElement = CoreMLElementDetector.convertBoundingBox(
            bbox: bbox, label: "A", confidence: 0.9,
            mapping: WindowPointMapping(
            imageWidth: 820, imageHeight: 1796, windowSize: windowSize, contentBounds: reducedBounds)
        )!

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
            mapping: WindowPointMapping(
            imageWidth: 820, imageHeight: 1796, windowSize: windowSize, contentBounds: contentBounds)
        )!

        #expect(element.text == "TextField")
        #expect(element.confidence == 0.75)
    }

    @Test("A dark app narrowing the content bounds on one axis is not scaled (carnet#103)")
    func testOneAxisNarrowedBoundsAreNotScaled() {
        // Clock on a 357x786 window: its black background narrowed the detected
        // bounds in width only, and icons on the right edge came out at x 790-808.
        let windowSize = CGSize(width: 357, height: 786)
        let darkBounds = CGRect(x: 0, y: 0, width: 300, height: 1572)
        let mapping = WindowPointMapping(
            imageWidth: 714, imageHeight: 1572, windowSize: windowSize, contentBounds: darkBounds)
        let toggle = CoreMLElementDetector.convertBoundingBox(
            bbox: CGRect(x: 0.82, y: 0.35, width: 0.12, height: 0.04),
            label: "icon", confidence: 0.9, mapping: mapping)
        #expect(mapping.bordersDetected == false)
        #expect(toggle != nil)
        #expect(abs((toggle?.tapX ?? 0) - 0.88 * 357) < 1.0)
    }

    @Test("A detection outside the window is dropped")
    func testDetectionOutsideTheWindowIsDropped() {
        let windowSize = CGSize(width: 357, height: 786)
        // Larger mode: content inside borders on both axes, scaled outward.
        let mapping = WindowPointMapping(
            imageWidth: 714, imageHeight: 1572, windowSize: windowSize,
            contentBounds: CGRect(x: 0, y: 0, width: 500, height: 1100))
        let edge = CoreMLElementDetector.convertBoundingBox(
            bbox: CGRect(x: 0.9, y: 0.5, width: 0.08, height: 0.04),
            label: "icon", confidence: 0.9, mapping: mapping)
        #expect(edge == nil, "scaled past the right edge, no tap there reaches the phone")
    }

    @Test("Icons and text at the same place map to the same point")
    func testIconAndTextShareOneMapping() {
        let windowSize = CGSize(width: 410, height: 898)
        let mapping = WindowPointMapping(
            imageWidth: 820, imageHeight: 1900, windowSize: windowSize,
            contentBounds: CGRect(x: 0, y: 0, width: 820, height: 1900))
        let bbox = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.05)
        let icon = CoreMLElementDetector.convertBoundingBox(
            bbox: bbox, label: "icon", confidence: 0.9, mapping: mapping)
        let text = mapping.element(text: "Label", bbox: bbox, confidence: 0.9)
        #expect(icon?.tapX == text.tapX)
        #expect(icon?.textTopY == text.textTopY)
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
