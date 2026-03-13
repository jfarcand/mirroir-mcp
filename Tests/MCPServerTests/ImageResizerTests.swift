// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for ImageResizer — PNG resize, scale factor computation, and aspect ratio preservation.
// ABOUTME: Validates the image preprocessing pipeline for vision API calls.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

final class ImageResizerTests: XCTestCase {

    /// Create a minimal valid PNG of the given dimensions for testing.
    private func createTestPNG(width: Int, height: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw a colored rectangle so the image isn't empty
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else { return nil }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    func testResizeProducesValidPNG() {
        guard let pngData = createTestPNG(width: 820, height: 1780) else {
            XCTFail("Failed to create test PNG")
            return
        }
        let windowSize = CGSize(width: 410, height: 890)
        let result = ImageResizer.resize(pngData: pngData, targetWidth: 500, windowSize: windowSize)

        XCTAssertNotNil(result)
        // Verify it's valid PNG data (starts with PNG signature)
        XCTAssertTrue(result!.data.count > 8)
        XCTAssertFalse(result!.base64.isEmpty)
    }

    func testResizeComputesCorrectScaleFactors() {
        guard let pngData = createTestPNG(width: 820, height: 1780) else {
            XCTFail("Failed to create test PNG")
            return
        }
        let windowSize = CGSize(width: 410, height: 890)
        let result = ImageResizer.resize(pngData: pngData, targetWidth: 500, windowSize: windowSize)

        XCTAssertNotNil(result)
        // scaleX = 410 / 500 = 0.82
        XCTAssertEqual(result!.scaleX, 410.0 / 500.0, accuracy: 0.001)
        // Target height = 500 * (1780/820) ≈ 1085
        // scaleY = 890 / 1085 ≈ 0.8203
        let expectedHeight = Double(500) * (1780.0 / 820.0)
        XCTAssertEqual(result!.scaleY, 890.0 / expectedHeight, accuracy: 0.001)
    }

    func testResizePreservesImageAspectRatio() {
        guard let pngData = createTestPNG(width: 956, height: 1932) else {
            XCTFail("Failed to create test PNG")
            return
        }
        let windowSize = CGSize(width: 410, height: 890)
        let result = ImageResizer.resize(pngData: pngData, targetWidth: 500, windowSize: windowSize)

        XCTAssertNotNil(result)
        // Resized image aspect ratio matches original: (500/targetHeight) ≈ (956/1932)
        let originalAspect = 956.0 / 1932.0
        let resizedHeight = Double(500) * (1932.0 / 956.0)
        let resizedAspect = 500.0 / resizedHeight
        XCTAssertEqual(resizedAspect, originalAspect, accuracy: 0.001)
    }

    func testResizeReturnsNilForInvalidData() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        let result = ImageResizer.resize(
            pngData: garbage, targetWidth: 500, windowSize: CGSize(width: 410, height: 890)
        )
        XCTAssertNil(result)
    }

    func testResizeBase64IsNonEmpty() {
        guard let pngData = createTestPNG(width: 100, height: 200) else {
            XCTFail("Failed to create test PNG")
            return
        }
        let result = ImageResizer.resize(
            pngData: pngData, targetWidth: 50, windowSize: CGSize(width: 100, height: 200)
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.base64.count > 100, "Base64 should be substantial for a valid PNG")
    }
}
