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
// ABOUTME: Tests for FrameFingerprint — deciding whether two captured frames show the same pixels.
// ABOUTME: Uses generated PNGs so the comparison is exercised on real encoded image data.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import mirroir_mcp

final class FrameFingerprintTests: XCTestCase {

    /// Encode a solid-colour image as PNG, the way a capture would arrive.
    private func makePNG(
        red: CGFloat, green: CGFloat, blue: CGFloat, size: Int = 8
    ) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    func testIdenticalPixelsCompareEqual() throws {
        let first = try XCTUnwrap(makePNG(red: 0.2, green: 0.4, blue: 0.6))
        let second = try XCTUnwrap(makePNG(red: 0.2, green: 0.4, blue: 0.6))
        XCTAssertTrue(FrameFingerprint.sameContent(first, second),
                      "Two captures of an unchanged screen must compare equal")
    }

    func testDifferentPixelsCompareUnequal() throws {
        let first = try XCTUnwrap(makePNG(red: 0.2, green: 0.4, blue: 0.6))
        let second = try XCTUnwrap(makePNG(red: 0.9, green: 0.1, blue: 0.1))
        XCTAssertFalse(FrameFingerprint.sameContent(first, second),
                       "A changed screen must not be reported as settled")
    }

    func testDifferentSizesCompareUnequal() throws {
        let small = try XCTUnwrap(makePNG(red: 0.5, green: 0.5, blue: 0.5, size: 8))
        let large = try XCTUnwrap(makePNG(red: 0.5, green: 0.5, blue: 0.5, size: 16))
        XCTAssertFalse(FrameFingerprint.sameContent(small, large))
    }

    func testUndecodableDataIsNeverReportedAsSettled() throws {
        let valid = try XCTUnwrap(makePNG(red: 0.2, green: 0.4, blue: 0.6))
        let garbage = Data([0x00, 0x01, 0x02, 0x03])

        // A failed decode is inconclusive, and inconclusive must not be mistaken
        // for "the screen stopped changing" — that would return a stale frame.
        XCTAssertFalse(FrameFingerprint.sameContent(garbage, garbage))
        XCTAssertFalse(FrameFingerprint.sameContent(valid, garbage))
        XCTAssertFalse(FrameFingerprint.sameContent(garbage, valid))
    }

    func testPixelsReturnsNilForNonImageData() {
        XCTAssertNil(FrameFingerprint.pixels(of: Data([0xFF, 0xD8, 0x00])))
    }

    func testPixelsDecodesRealPNG() throws {
        let png = try XCTUnwrap(makePNG(red: 1, green: 1, blue: 1))
        let pixels = try XCTUnwrap(FrameFingerprint.pixels(of: png))
        XCTAssertFalse(pixels.isEmpty)
    }
}
