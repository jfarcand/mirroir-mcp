// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for IconDetector: unlabeled icon detection via pixel clustering and saliency.
// ABOUTME: Uses synthetic CGImages to verify icon detection, OCR filtering, and coordinate mapping.

import CoreGraphics
import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class IconDetectorTests: XCTestCase {

    // MARK: - Test Helpers

    /// Create a test image with colored rectangles on a solid background.
    ///
    /// - Parameters:
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - icons: Array of (x, y, size) tuples specifying icon rectangles in pixel coordinates.
    ///   - bgR, bgG, bgB: Background color components.
    ///   - iconR, iconG, iconB: Icon color components.
    /// - Returns: A `CGImage` with the specified icons drawn on the background.
    private func createTestImage(
        width: Int, height: Int,
        icons: [(x: Int, y: Int, size: Int)],
        bgR: UInt8 = 255, bgG: UInt8 = 255, bgB: UInt8 = 255,
        iconR: UInt8 = 50, iconG: UInt8 = 50, iconB: UInt8 = 50
    ) -> CGImage {
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)

        // Fill background
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixelData[offset] = bgR
                pixelData[offset + 1] = bgG
                pixelData[offset + 2] = bgB
                pixelData[offset + 3] = 255
            }
        }

        // Draw icon rectangles
        for icon in icons {
            for dy in 0..<icon.size {
                for dx in 0..<icon.size {
                    let px = icon.x + dx
                    let py = icon.y + dy
                    guard px < width, py < height else { continue }
                    let offset = py * bytesPerRow + px * 4
                    pixelData[offset] = iconR
                    pixelData[offset + 1] = iconG
                    pixelData[offset + 2] = iconB
                    pixelData[offset + 3] = 255
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        return ctx.makeImage()!
    }

    // MARK: - Empty Zone Detection

    func testEmptyZoneDetectionFindsBottomZone() {
        // Elements only in the upper part of the screen — bottom zone should be empty
        let elements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        let windowHeight = 898.0
        let windowWidth = 410.0

        let zones = IconDetector.findEmptyZones(
            ocrElements: elements, windowWidth: windowWidth, windowHeight: windowHeight
        )

        XCTAssertFalse(zones.isEmpty, "Should find at least the bottom zone")
        let bottomZone = zones.first { $0.yStart > windowHeight * 0.5 }
        XCTAssertNotNil(bottomZone, "Should find a bottom zone")
    }

    func testEmptyZoneDetectionSkipsPopulatedZones() {
        // Elements spread across the entire screen including bottom
        let windowHeight = 898.0
        let windowWidth = 410.0
        let elements = [
            TapPoint(text: "Home", tapX: 56, tapY: 870, confidence: 0.95),
            TapPoint(text: "Search", tapX: 158, tapY: 870, confidence: 0.95),
        ]

        let zones = IconDetector.findEmptyZones(
            ocrElements: elements, windowWidth: windowWidth, windowHeight: windowHeight
        )

        let bottomZone = zones.first { $0.yStart > windowHeight * 0.5 }
        XCTAssertNil(bottomZone,
            "Bottom zone with 2 OCR elements should not be considered empty")
    }

    // MARK: - Pixel Clustering

    func testDetectsIconsOnSolidBackground() {
        // Simulate a tab bar: 4 icons evenly spaced on a white background
        // Image is 820x1796 pixels (2x of 410x898 window)
        let imgWidth = 820
        let imgHeight = 1796
        let windowSize = CGSize(width: 410, height: 898)

        // Place 4 icons in the bottom 8% (pixel y > 1652, i.e. window y > 826)
        let iconY = 1700
        let iconSize = 50  // 25pt at 2x
        let icons = [
            (x: 80, y: iconY, size: iconSize),
            (x: 260, y: iconY, size: iconSize),
            (x: 440, y: iconY, size: iconSize),
            (x: 620, y: iconY, size: iconSize),
        ]

        let image = createTestImage(width: imgWidth, height: imgHeight, icons: icons)

        let detected = IconDetector.detect(
            image: image, ocrElements: [], windowSize: windowSize
        )

        XCTAssertEqual(detected.count, 4,
            "Should detect 4 icons, got \(detected.count)")

        // Verify icons are in the bottom portion of window coordinates
        for icon in detected {
            XCTAssertGreaterThan(icon.tapY, windowSize.height * 0.8,
                "Icon should be in bottom area, got tapY=\(icon.tapY)")
        }
    }

    func testNoIconsOnBlankImage() {
        // All-white image with no dark objects
        let image = createTestImage(width: 820, height: 1796, icons: [])
        let windowSize = CGSize(width: 410, height: 898)

        let detected = IconDetector.detect(
            image: image, ocrElements: [], windowSize: windowSize
        )

        XCTAssertTrue(detected.isEmpty,
            "Blank image should produce no detected icons")
    }

    func testNoIconsWhenZoneHasOCRElements() {
        // Provide enough TapPoints in the bottom zone so it's not "empty"
        let windowSize = CGSize(width: 410, height: 898)
        let elements = [
            TapPoint(text: "Home", tapX: 56, tapY: 870, confidence: 0.95),
            TapPoint(text: "Search", tapX: 158, tapY: 870, confidence: 0.95),
        ]

        // Put icons in the tab bar area
        let image = createTestImage(
            width: 820, height: 1796,
            icons: [(x: 80, y: 1700, size: 50), (x: 260, y: 1700, size: 50)]
        )

        let detected = IconDetector.detect(
            image: image, ocrElements: elements, windowSize: windowSize
        )

        XCTAssertTrue(detected.isEmpty,
            "Should not detect icons when zone has enough OCR elements")
    }

    func testFiltersDuplicatesNearOCR() {
        // Place an icon and a nearby TapPoint — icon should be filtered
        let windowSize = CGSize(width: 410, height: 898)
        let image = createTestImage(
            width: 820, height: 1796,
            icons: [(x: 200, y: 1700, size: 50)]
        )

        // TapPoint near the expected icon position (~100pt window X, ~800pt window Y)
        let elements = [
            TapPoint(text: "H", tapX: 102, tapY: 800, confidence: 0.95)
        ]

        // The zone has <= 1 element so it's still scanned, but icon near OCR is removed
        let detected = IconDetector.detect(
            image: image, ocrElements: elements, windowSize: windowSize
        )

        // If the detected icon is within 20pt of the OCR element, it should be filtered
        for icon in detected {
            let dx = icon.tapX - 102.0
            let dy = icon.tapY - 800.0
            let dist = (dx * dx + dy * dy).squareRoot()
            XCTAssertGreaterThanOrEqual(dist, EnvConfig.iconOcrProximityFilter,
                "Icons within \(EnvConfig.iconOcrProximityFilter)pt of OCR should be filtered")
        }
    }

    func testIconsReturnedInWindowCoordinates() {
        let windowSize = CGSize(width: 410, height: 898)
        let image = createTestImage(
            width: 820, height: 1796,
            icons: [
                (x: 100, y: 1700, size: 50),
                (x: 400, y: 1700, size: 50),
            ]
        )

        let detected = IconDetector.detect(
            image: image, ocrElements: [], windowSize: windowSize
        )

        for icon in detected {
            XCTAssertGreaterThanOrEqual(icon.tapX, 0,
                "tapX should be >= 0, got \(icon.tapX)")
            XCTAssertLessThanOrEqual(icon.tapX, Double(windowSize.width),
                "tapX should be <= window width, got \(icon.tapX)")
            XCTAssertGreaterThanOrEqual(icon.tapY, 0,
                "tapY should be >= 0, got \(icon.tapY)")
            XCTAssertLessThanOrEqual(icon.tapY, Double(windowSize.height),
                "tapY should be <= window height, got \(icon.tapY)")
        }
    }

    func testFilterNearOCRLogic() {
        let icons = [
            IconDetector.DetectedIcon(tapX: 100, tapY: 850, estimatedSize: 25),
            IconDetector.DetectedIcon(tapX: 200, tapY: 850, estimatedSize: 25),
            IconDetector.DetectedIcon(tapX: 300, tapY: 850, estimatedSize: 25),
        ]
        let ocrElements = [
            TapPoint(text: "X", tapX: 102, tapY: 848, confidence: 0.9)
        ]

        let filtered = IconDetector.filterNearOCR(icons: icons, ocrElements: ocrElements)

        XCTAssertEqual(filtered.count, 2,
            "Icon at (100,850) should be filtered (within 20pt of OCR at 102,848)")
        XCTAssertTrue(filtered.allSatisfy { $0.tapX != 100 },
            "The icon at tapX=100 should have been removed")
    }

    func testInterpolateEvenSpacingFillsGaps() {
        // Simulate detecting 3 of 5 tab bar icons (Reels, DMs, Search)
        // at ~80pt spacing. Should extrapolate Home (left) and Profile (right).
        let detected = [
            IconDetector.DetectedIcon(tapX: 130, tapY: 838, estimatedSize: 25),
            IconDetector.DetectedIcon(tapX: 210, tapY: 838, estimatedSize: 25),
            IconDetector.DetectedIcon(tapX: 290, tapY: 838, estimatedSize: 25),
        ]
        let zone = IconDetector.EmptyZone(yStart: 826, yEnd: 898)

        let result = IconDetector.interpolateEvenSpacing(
            detected: detected, windowWidth: 410, zone: zone
        )

        XCTAssertEqual(result.count, 5,
            "Should interpolate 2 missing icons (left and right), got \(result.count)")
        let sortedX = result.map(\.tapX).sorted()
        // Expect ~50, ~130, ~210, ~290, ~370
        XCTAssertEqual(sortedX[0], 50, accuracy: 5, "Leftmost interpolated icon")
        XCTAssertEqual(sortedX[4], 370, accuracy: 5, "Rightmost interpolated icon")
    }

    func testInterpolateSkipsWithTooFewIcons() {
        // Only 1 icon — not enough to determine spacing
        let detected = [
            IconDetector.DetectedIcon(tapX: 200, tapY: 838, estimatedSize: 25),
        ]
        let zone = IconDetector.EmptyZone(yStart: 826, yEnd: 898)

        let result = IconDetector.interpolateEvenSpacing(
            detected: detected, windowWidth: 410, zone: zone
        )

        XCTAssertEqual(result.count, 1,
            "Should not interpolate with only 1 icon")
    }

    func testInterpolateSkipsUnevenSpacing() {
        // Icons at irregular spacing — should not interpolate
        let detected = [
            IconDetector.DetectedIcon(tapX: 50, tapY: 838, estimatedSize: 25),
            IconDetector.DetectedIcon(tapX: 200, tapY: 838, estimatedSize: 25),
            IconDetector.DetectedIcon(tapX: 230, tapY: 838, estimatedSize: 25),
        ]
        let zone = IconDetector.EmptyZone(yStart: 826, yEnd: 898)

        let result = IconDetector.interpolateEvenSpacing(
            detected: detected, windowWidth: 410, zone: zone
        )

        XCTAssertEqual(result.count, 3,
            "Should not interpolate when spacing is uneven")
    }

    func testMergeDetectionsDeduplicatesNearby() {
        let primary = [
            IconDetector.DetectedIcon(tapX: 50, tapY: 850, estimatedSize: 25),
            IconDetector.DetectedIcon(tapX: 200, tapY: 850, estimatedSize: 25),
        ]
        let secondary = [
            // Near primary (50, 850) — should be deduplicated
            IconDetector.DetectedIcon(tapX: 55, tapY: 852, estimatedSize: 20),
            // Far from all primaries — should be added
            IconDetector.DetectedIcon(tapX: 350, tapY: 850, estimatedSize: 22),
        ]

        let merged = IconDetector.mergeDetections(primary: primary, secondary: secondary)

        XCTAssertEqual(merged.count, 3,
            "Should keep 2 primaries + 1 non-duplicate secondary, got \(merged.count)")
        XCTAssertTrue(merged.contains { $0.tapX == 350 },
            "Secondary icon at tapX=350 should be included")
    }

    func testSaliencyFallbackOnGradientBackground() {
        // Create an image with a gradient-like background and dark icons
        // The gradient makes clustering unreliable; saliency should find icons
        let imgWidth = 820
        let imgHeight = 1796
        let windowSize = CGSize(width: 410, height: 898)

        let bytesPerRow = imgWidth * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * imgHeight)

        // Fill with a vertical gradient in the bottom zone
        for y in 0..<imgHeight {
            let gray = UInt8(min(255, 100 + (y * 155 / imgHeight)))
            for x in 0..<imgWidth {
                let offset = y * bytesPerRow + x * 4
                pixelData[offset] = gray
                pixelData[offset + 1] = gray
                pixelData[offset + 2] = gray
                pixelData[offset + 3] = 255
            }
        }

        // Draw high-contrast icons in the bottom zone
        let iconPositions = [(100, 1700), (300, 1700), (500, 1700), (700, 1700)]
        for (ix, iy) in iconPositions {
            for dy in 0..<40 {
                for dx in 0..<40 {
                    let px = ix + dx
                    let py = iy + dy
                    guard px < imgWidth, py < imgHeight else { continue }
                    let offset = py * bytesPerRow + px * 4
                    pixelData[offset] = 0
                    pixelData[offset + 1] = 0
                    pixelData[offset + 2] = 0
                    pixelData[offset + 3] = 255
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixelData,
            width: imgWidth,
            height: imgHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = ctx.makeImage()!

        let detected = IconDetector.detect(
            image: image, ocrElements: [], windowSize: windowSize
        )

        // Saliency results are approximate — just verify we found some icons
        // in the bottom portion. The gradient background may cause clustering
        // to partially succeed or fail, triggering the saliency fallback.
        XCTAssertFalse(detected.isEmpty,
            "Should detect icons even on gradient background (via clustering or saliency)")
    }
}
