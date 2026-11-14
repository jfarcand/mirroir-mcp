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
// ABOUTME: Unit tests for VisualFingerprint: perceptual hashing, Hamming distance, and DCT correctness.
// ABOUTME: Verifies hash stability, distance symmetry, and visual similarity detection.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

final class VisualFingerprintTests: XCTestCase {

    // MARK: - Test Helpers

    /// Create a small solid-color CGImage for testing.
    private func makeSolidImage(width: Int, height: Int, gray: UInt8) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        let grayFloat = CGFloat(gray) / 255.0
        context.setFillColor(gray: grayFloat, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage()
    }

    /// Create a CGImage with a horizontal gradient for testing.
    private func makeGradientImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Draw a horizontal gradient by filling column strips
        for x in 0..<width {
            let grayValue = CGFloat(x) / CGFloat(width - 1)
            context.setFillColor(gray: grayValue, alpha: 1.0)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }

        return context.makeImage()
    }

    // MARK: - Hash Computation

    func testInvalidBase64ReturnsZero() {
        let hash = VisualFingerprint.compute(screenshotBase64: "not-valid-base64!!!")

        XCTAssertEqual(hash, 0,
            "Invalid base64 should return 0 hash")
    }

    func testEmptyStringReturnsZero() {
        let hash = VisualFingerprint.compute(screenshotBase64: "")

        XCTAssertEqual(hash, 0,
            "Empty string should return 0 hash")
    }

    func testSolidImageProducesConsistentHash() {
        guard let image = makeSolidImage(width: 64, height: 64, gray: 128) else {
            XCTFail("Failed to create test image")
            return
        }

        let hash1 = VisualFingerprint.computeFromCGImage(image)
        let hash2 = VisualFingerprint.computeFromCGImage(image)

        XCTAssertEqual(hash1, hash2,
            "Same image should produce identical hash")
    }

    func testDifferentImagesProduceDifferentHashes() {
        guard let black = makeSolidImage(width: 64, height: 64, gray: 0),
              let gradient = makeGradientImage(width: 64, height: 64) else {
            XCTFail("Failed to create test images")
            return
        }

        let hashBlack = VisualFingerprint.computeFromCGImage(black)
        let hashGradient = VisualFingerprint.computeFromCGImage(gradient)

        // A solid black image and a gradient should have different hashes
        // (though the solid image might hash to 0 or all-same since DCT coefficients
        // are all equal, the gradient will have frequency content)
        XCTAssertNotEqual(hashBlack, hashGradient,
            "Visually different images should produce different hashes")
    }

    // MARK: - Hamming Distance

    func testDistanceIdenticalHashesIsZero() {
        let hash: UInt64 = 0xDEAD_BEEF_CAFE_BABE

        let dist = VisualFingerprint.distance(hash, hash)

        XCTAssertEqual(dist, 0,
            "Distance between identical hashes should be 0")
    }

    func testDistanceIsSymmetric() {
        let a: UInt64 = 0xFF00_FF00_FF00_FF00
        let b: UInt64 = 0x00FF_00FF_00FF_00FF

        XCTAssertEqual(
            VisualFingerprint.distance(a, b),
            VisualFingerprint.distance(b, a),
            "Hamming distance should be symmetric"
        )
    }

    func testDistanceSingleBitDifference() {
        let a: UInt64 = 0
        let b: UInt64 = 1

        XCTAssertEqual(VisualFingerprint.distance(a, b), 1,
            "Single bit difference should yield distance 1")
    }

    func testDistanceMaxDifference() {
        let a: UInt64 = 0
        let b: UInt64 = UInt64.max

        XCTAssertEqual(VisualFingerprint.distance(a, b), 64,
            "All bits different should yield distance 64")
    }

    func testDistanceKnownValue() {
        // 0b1010 vs 0b1100 differ in bits 1 and 2 → distance 2
        let a: UInt64 = 0b1010
        let b: UInt64 = 0b1100

        XCTAssertEqual(VisualFingerprint.distance(a, b), 2)
    }

    // MARK: - Similarity Threshold

    func testSimilarityThresholdIsReasonable() {
        XCTAssertGreaterThan(VisualFingerprint.similarityThreshold, 0,
            "Threshold should be positive")
        XCTAssertLessThanOrEqual(VisualFingerprint.similarityThreshold, 32,
            "Threshold should be at most half the hash size")
    }

    // MARK: - Visual Similarity

    func testSimilarImagesHaveSmallDistance() {
        // Two gradient images of slightly different sizes produce similar frequency content.
        // Solid images are unsuitable: their flat DCT spectra cause median-threshold instability.
        guard let grad1 = makeGradientImage(width: 64, height: 64),
              let grad2 = makeGradientImage(width: 66, height: 66) else {
            XCTFail("Failed to create test images")
            return
        }

        let hash1 = VisualFingerprint.computeFromCGImage(grad1)
        let hash2 = VisualFingerprint.computeFromCGImage(grad2)
        let dist = VisualFingerprint.distance(hash1, hash2)

        XCTAssertLessThanOrEqual(dist, VisualFingerprint.similarityThreshold,
            "Structurally similar images should be within similarity threshold. Distance: \(dist)")
    }

    // MARK: - Integration with ScreenNode

    func testScreenNodeVisualHashFieldExists() {
        // Verify the optional visualHash field is accessible on ScreenNode
        let node = ScreenNode(
            fingerprint: "test",
            elements: [],
            icons: [],
            hints: [],
            depth: 0,
            screenType: .unknown,
            screenshotBase64: "",
            visitedElements: [],
            navBarTitle: nil,
            visualHash: 42
        )

        XCTAssertEqual(node.visualHash, 42,
            "ScreenNode should store visual hash")
    }

    func testScreenNodeVisualHashDefaultsToNil() {
        let node = ScreenNode(
            fingerprint: "test",
            elements: [],
            icons: [],
            hints: [],
            depth: 0,
            screenType: .unknown,
            screenshotBase64: "",
            visitedElements: [],
            navBarTitle: nil
        )

        XCTAssertNil(node.visualHash,
            "ScreenNode visualHash should default to nil")
    }

    // MARK: - CGImage Direct API

    func testComputeFromCGImageGradient() {
        guard let gradient = makeGradientImage(width: 100, height: 100) else {
            XCTFail("Failed to create gradient image")
            return
        }

        let hash = VisualFingerprint.computeFromCGImage(gradient)

        // Gradient has clear frequency content, so hash should be non-zero
        XCTAssertNotEqual(hash, 0,
            "Gradient image should produce a non-zero hash")
    }

    func testHashDeterministic() {
        guard let image = makeGradientImage(width: 80, height: 120) else {
            XCTFail("Failed to create test image")
            return
        }

        let hashes = (0..<5).map { _ in VisualFingerprint.computeFromCGImage(image) }
        let allSame = hashes.allSatisfy { $0 == hashes[0] }

        XCTAssertTrue(allSame,
            "Hash should be deterministic across multiple computations")
    }
}
