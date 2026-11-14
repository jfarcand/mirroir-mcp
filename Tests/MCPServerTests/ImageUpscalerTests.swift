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
// ABOUTME: Tests for ImageUpscaler — validates upscaling behavior, threshold logic, and aspect ratio.
// ABOUTME: Ensures small screenshots are upscaled while already-large images pass through unchanged.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

final class ImageUpscalerTests: XCTestCase {

    /// Create a test CGImage of the given dimensions.
    private func createTestImage(width: Int, height: Int) -> CGImage? {
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

        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    func testUpscaleSmallImage() {
        guard let image = createTestImage(width: 200, height: 400) else {
            XCTFail("Failed to create test image")
            return
        }
        let result = ImageUpscaler.upscaleIfNeeded(image: image, minWidth: 600)

        XCTAssertEqual(result.width, 600)
        XCTAssertEqual(result.height, 1200)
    }

    func testNoUpscaleWhenAlreadyLargeEnough() {
        guard let image = createTestImage(width: 800, height: 1600) else {
            XCTFail("Failed to create test image")
            return
        }
        let result = ImageUpscaler.upscaleIfNeeded(image: image, minWidth: 600)

        XCTAssertEqual(result.width, 800)
        XCTAssertEqual(result.height, 1600)
    }

    func testNoUpscaleExactlyAtThreshold() {
        guard let image = createTestImage(width: 600, height: 1200) else {
            XCTFail("Failed to create test image")
            return
        }
        let result = ImageUpscaler.upscaleIfNeeded(image: image, minWidth: 600)

        XCTAssertEqual(result.width, 600)
        XCTAssertEqual(result.height, 1200)
    }

    func testUpscalePreservesAspectRatio() {
        guard let image = createTestImage(width: 424, height: 942) else {
            XCTFail("Failed to create test image")
            return
        }
        let originalAspect = Double(image.height) / Double(image.width)
        let result = ImageUpscaler.upscaleIfNeeded(image: image, minWidth: 600)

        let resultAspect = Double(result.height) / Double(result.width)
        XCTAssertEqual(resultAspect, originalAspect, accuracy: 0.01)
        XCTAssertEqual(result.width, 600)
    }
}
