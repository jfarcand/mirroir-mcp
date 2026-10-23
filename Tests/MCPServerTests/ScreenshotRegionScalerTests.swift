// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for ScreenshotRegionScaler — region crop + downscale of screenshot PNGs.
// ABOUTME: Validates output pixel dimensions, the no-op path, and failure handling.

import CoreGraphics
import ImageIO
import XCTest
@testable import mirroir_mcp

final class ScreenshotRegionScalerTests: XCTestCase {

    /// Create a minimal valid PNG of the given pixel dimensions.
    private func createTestPNG(width: Int, height: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
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

    /// Decode a PNG and return its pixel dimensions.
    private func pngPixelSize(_ data: Data) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return (img.width, img.height)
    }

    // 2x Retina frame: 820x1780 px over a 410x890-point window (backingScale 2).
    private let windowSize = CGSize(width: 410, height: 890)

    func testNilRegionAndScaleReturnsOriginalBytes() {
        guard let png = createTestPNG(width: 820, height: 1780) else {
            XCTFail("fixture"); return
        }
        let out = ScreenshotRegionScaler.transform(
            pngData: png, windowSize: windowSize, region: nil, scale: nil)
        XCTAssertEqual(out, png, "both nil is a no-op that returns the input unchanged")
    }

    func testScaleHalvesPixelDimensions() {
        guard let png = createTestPNG(width: 820, height: 1780) else {
            XCTFail("fixture"); return
        }
        let out = ScreenshotRegionScaler.transform(
            pngData: png, windowSize: windowSize, region: nil, scale: 0.5)
        XCTAssertNotNil(out)
        let size = pngPixelSize(out!)
        XCTAssertEqual(size?.w, 410)
        XCTAssertEqual(size?.h, 890)
    }

    func testRegionCropsInPixelSpace() {
        guard let png = createTestPNG(width: 820, height: 1780) else {
            XCTFail("fixture"); return
        }
        // Region in window points; backingScale 2 → pixel crop 200x400.
        let out = ScreenshotRegionScaler.transform(
            pngData: png, windowSize: windowSize,
            region: CGRect(x: 0, y: 0, width: 100, height: 200), scale: nil)
        XCTAssertNotNil(out)
        let size = pngPixelSize(out!)
        XCTAssertEqual(size?.w, 200)
        XCTAssertEqual(size?.h, 400)
    }

    func testRegionAndScaleCompose() {
        guard let png = createTestPNG(width: 820, height: 1780) else {
            XCTFail("fixture"); return
        }
        // 100x200 points → 200x400 px crop, then 0.5 scale → 100x200 px.
        let out = ScreenshotRegionScaler.transform(
            pngData: png, windowSize: windowSize,
            region: CGRect(x: 0, y: 0, width: 100, height: 200), scale: 0.5)
        XCTAssertNotNil(out)
        let size = pngPixelSize(out!)
        XCTAssertEqual(size?.w, 100)
        XCTAssertEqual(size?.h, 200)
    }

    func testRegionClampsToImageBounds() {
        guard let png = createTestPNG(width: 820, height: 1780) else {
            XCTFail("fixture"); return
        }
        // Region wider/taller than the window — clamped to the full frame.
        let out = ScreenshotRegionScaler.transform(
            pngData: png, windowSize: windowSize,
            region: CGRect(x: 0, y: 0, width: 9999, height: 9999), scale: nil)
        XCTAssertNotNil(out)
        let size = pngPixelSize(out!)
        XCTAssertEqual(size?.w, 820)
        XCTAssertEqual(size?.h, 1780)
    }

    func testReturnsNilForInvalidData() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        let out = ScreenshotRegionScaler.transform(
            pngData: garbage, windowSize: windowSize,
            region: nil, scale: 0.5)
        XCTAssertNil(out)
    }
}
