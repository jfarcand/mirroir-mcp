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
// ABOUTME: Tests for ContentBoundsDetector that finds iOS content bounds within mirroring screenshots.
// ABOUTME: Uses synthetic CGImages to validate border detection, fallback behavior, and edge cases.

import CoreGraphics
import Foundation
import Testing
@testable import HelperLib

@Suite("ContentBoundsDetector")
struct ContentBoundsDetectorTests {

    /// Create a CGImage filled with a solid color.
    private func makeImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
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
        ctx.setFillColor(
            CGColor(
                colorSpace: colorSpace,
                components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1.0]
            )!
        )
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Create a CGImage with content in a specific rect and dark (black) borders elsewhere.
    /// Simulates the iPhone Mirroring "Larger" mode where content doesn't fill the window.
    private func makeImageWithContent(
        imageWidth: Int, imageHeight: Int,
        contentX: Int, contentY: Int, contentWidth: Int, contentHeight: Int,
        r: UInt8, g: UInt8, b: UInt8
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: imageWidth,
            height: imageHeight,
            bitsPerComponent: 8,
            bytesPerRow: imageWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Fill entire image with black (dark border)
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

        // Fill content area with the specified color
        // CGContext origin is bottom-left, so convert contentY from top-left
        let cgContentY = imageHeight - contentY - contentHeight
        ctx.setFillColor(
            CGColor(
                colorSpace: colorSpace,
                components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1.0]
            )!
        )
        ctx.fill(CGRect(x: contentX, y: cgContentY, width: contentWidth, height: contentHeight))
        return ctx.makeImage()!
    }

    @Test("full content (no border) returns full image rect")
    func noBorder() {
        // Entire image is bright content — no dark borders
        let image = makeImage(width: 820, height: 1796, r: 128, g: 128, b: 128)
        let result = ContentBoundsDetector.detect(image: image)

        #expect(Int(result.origin.x) == 0)
        #expect(Int(result.origin.y) == 0)
        #expect(Int(result.width) == 820)
        #expect(Int(result.height) == 1796)
    }

    @Test("right and bottom borders detected (Larger mode simulation)")
    func rightAndBottomBorders() {
        // Simulates iPhone 16 in "Larger" mode: 410pt window (820px @2x), content is 393pt (786px)
        // Content starts at top-left (0,0), with dark borders on right and bottom
        let image = makeImageWithContent(
            imageWidth: 820, imageHeight: 1796,
            contentX: 0, contentY: 0, contentWidth: 786, contentHeight: 1704,
            r: 100, g: 150, b: 200
        )
        let result = ContentBoundsDetector.detect(image: image)

        #expect(Int(result.origin.x) == 0)
        #expect(Int(result.origin.y) == 0)
        #expect(Int(result.width) == 786)
        #expect(Int(result.height) == 1704)
    }

    @Test("centered content ignores left/top borders (only right/bottom detected)")
    func centeredContentIgnoresLeftTop() {
        // Content centered with borders on all four sides.
        // Detector only finds right and bottom edges; origin stays at (0,0).
        // Width = right edge of content (50 + 700 = 750), height = bottom edge (50 + 700 = 750).
        let image = makeImageWithContent(
            imageWidth: 800, imageHeight: 800,
            contentX: 50, contentY: 50, contentWidth: 700, contentHeight: 700,
            r: 200, g: 200, b: 200
        )
        let result = ContentBoundsDetector.detect(image: image)

        #expect(Int(result.origin.x) == 0)
        #expect(Int(result.origin.y) == 0)
        #expect(Int(result.width) == 750)
        #expect(Int(result.height) == 750)
    }

    @Test("all-black image returns full rect as fallback")
    func allBlackFallback() {
        // Entirely dark image — detector cannot find content, should fall back to full rect
        let image = makeImage(width: 400, height: 600, r: 0, g: 0, b: 0)
        let result = ContentBoundsDetector.detect(image: image)

        #expect(Int(result.origin.x) == 0)
        #expect(Int(result.origin.y) == 0)
        #expect(Int(result.width) == 400)
        #expect(Int(result.height) == 600)
    }

    @Test("content with dark edges detects right and bottom only")
    func darkEdgesWithContent() {
        // Content area includes some dark-ish pixels near edges, but the interior
        // has clearly non-dark pixels that the scanlines (at 30-70%) should detect.
        // A 10px dark perimeter inside the content, but bright interior beyond that.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let width = 600
        let height = 600
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Start with all black
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Content area 100..500 (400px wide/tall) with 10px dark border inside
        // Bright interior: 110..490
        let bright = CGColor(colorSpace: colorSpace, components: [0.5, 0.6, 0.7, 1])!
        ctx.setFillColor(bright)
        // CG origin bottom-left: content from y=100 to y=500 in top-down →
        // CG y = 600-500=100 to 600-100=500, so fill at CG (110, 110, 380, 380)
        ctx.fill(CGRect(x: 110, y: 110, width: 380, height: 380))

        let image = ctx.makeImage()!
        let result = ContentBoundsDetector.detect(image: image)

        // Scanlines at 30-70% of 600 = 180,240,300,360,420 — all hit the bright interior.
        // Only right (x=490) and bottom (y=490) edges detected; origin stays at (0,0).
        #expect(Int(result.origin.x) == 0)
        #expect(Int(result.origin.y) == 0)
        #expect(Int(result.width) == 490)
        #expect(Int(result.height) == 490)
    }

    @Test("small asymmetric bottom-right border")
    func smallBorder() {
        // Content fills most of the image with a small border on right (20px) and bottom (30px)
        let image = makeImageWithContent(
            imageWidth: 500, imageHeight: 500,
            contentX: 0, contentY: 0, contentWidth: 480, contentHeight: 470,
            r: 80, g: 80, b: 80
        )
        let result = ContentBoundsDetector.detect(image: image)

        #expect(Int(result.origin.x) == 0)
        #expect(Int(result.origin.y) == 0)
        #expect(Int(result.width) == 480)
        #expect(Int(result.height) == 470)
    }

    @Test("brightness threshold excludes near-black pixels")
    func nearBlackExcluded() {
        // Image where border pixels are slightly non-zero (e.g., 15/255) but below threshold
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let width = 400
        let height = 400
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Fill with near-black (below threshold of 20)
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [15.0 / 255, 15.0 / 255, 15.0 / 255, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Content in center: 50..350 = 300px wide/tall
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.5, 0.5, 0.5, 1])!)
        // CG y for top-down 50..350: CG fill at y=50, height=300
        ctx.fill(CGRect(x: 50, y: 50, width: 300, height: 300))

        let image = ctx.makeImage()!
        let result = ContentBoundsDetector.detect(image: image)

        // Near-black border treated as dark. Only right (350) and bottom (350) detected.
        #expect(Int(result.origin.x) == 0)
        #expect(Int(result.origin.y) == 0)
        #expect(Int(result.width) == 350)
        #expect(Int(result.height) == 350)
    }
}
