// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Pixel-level icon detection via column-projection clustering.
// ABOUTME: Analyzes RGBA pixel buffers to find foreground clusters that match icon dimensions.

import CoreGraphics
import Foundation
import HelperLib

/// Low-level pixel analysis for detecting icon-shaped clusters on solid-color backgrounds.
/// Uses column-projection: count foreground pixels per column, smooth, and find peaks
/// whose width matches expected icon dimensions (10–80px).
enum IconClusterDetector {

    // MARK: - Detection

    /// Detect icons via column-projection on a solid-color background.
    /// Renders the full image to an RGBA buffer, then indexes into the zone's
    /// pixel rows to detect foreground clusters via column density analysis.
    static func detect(
        image: CGImage,
        zone: IconDetector.EmptyZone,
        contentRect: CGRect,
        displayScale: Double,
        windowWidth: Double,
        windowHeight: Double
    ) -> [IconDetector.DetectedIcon] {
        let contentOriginX = Double(contentRect.minX) / displayScale
        let contentOriginY = Double(contentRect.minY) / displayScale
        let contentWidth = Double(contentRect.width) / displayScale
        let contentHeight = Double(contentRect.height) / displayScale
        let xScale = windowWidth / max(contentWidth, 1.0)
        let yScale = windowHeight / max(contentHeight, 1.0)

        let imgWidth = image.width
        let imgHeight = image.height

        // Render full image to RGBA buffer (same approach as ContentBoundsDetector)
        let bytesPerRow = imgWidth * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * imgHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixelData,
            width: imgWidth,
            height: imgHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight))

        // Convert zone window coordinates to pixel row range
        let pixelYStart = Int(((zone.yStart / yScale) + contentOriginY) * displayScale)
        let pixelYEnd = Int(((zone.yEnd / yScale) + contentOriginY) * displayScale)
        let rowStart = max(0, pixelYStart)
        let rowEnd = min(imgHeight, pixelYEnd)
        let cropHeight = rowEnd - rowStart

        guard cropHeight > 0 else { return [] }

        // Detect background color from edge pixels within the zone
        let bgColor = detectBackgroundColor(
            pixels: pixelData, width: imgWidth, rowStart: rowStart,
            rowEnd: rowEnd, bytesPerRow: bytesPerRow
        )

        // Filter to "bar rows" — rows where most pixels match the background.
        // This excludes photo/content rows that bleed into the zone.
        let barRows = findBarRows(
            pixels: pixelData, width: imgWidth, rowStart: rowStart,
            rowEnd: rowEnd, bytesPerRow: bytesPerRow, background: bgColor
        )

        guard !barRows.isEmpty else { return [] }

        // Column projection: count foreground pixels per column within bar rows only
        var projection = [Int](repeating: 0, count: imgWidth)
        for x in 0..<imgWidth {
            var count = 0
            for row in barRows {
                let offset = row * bytesPerRow + x * 4
                if differsByThreshold(pixelData, at: offset, background: bgColor) {
                    count += 1
                }
            }
            projection[x] = count
        }

        // Smooth projection with box filter
        let smoothed = boxFilter(projection, windowSize: EnvConfig.iconSmoothingWindow)

        // Find peaks: contiguous runs above minColumnDensity
        var icons: [IconDetector.DetectedIcon] = []
        var runStart: Int?
        for x in 0...imgWidth {
            let val = x < imgWidth ? smoothed[x] : 0
            if val >= EnvConfig.iconMinColumnDensity {
                if runStart == nil { runStart = x }
            } else if let start = runStart {
                let width = x - start
                if width >= EnvConfig.iconMinClusterWidth && width <= EnvConfig.iconMaxClusterWidth {
                    // Find vertical centroid of foreground pixels in this run
                    let centerX = Double(start + x) / 2.0
                    let centerY = findVerticalCentroid(
                        pixels: pixelData, xStart: start, xEnd: x,
                        rows: barRows,
                        bytesPerRow: bytesPerRow, background: bgColor
                    )

                    // Convert pixel coordinates back to window coordinates
                    let windowX = ((centerX / displayScale) - contentOriginX) * xScale
                    let windowY = ((centerY / displayScale) - contentOriginY) * yScale
                    let iconSize = Double(width) / displayScale

                    if windowX >= 0 && windowX <= windowWidth
                        && windowY >= 0 && windowY <= windowHeight {
                        icons.append(IconDetector.DetectedIcon(
                            tapX: windowX, tapY: windowY, estimatedSize: iconSize
                        ))
                    }
                }
                runStart = nil
            }
        }

        return icons
    }

    // MARK: - Pixel Helpers

    /// Background color as (R, G, B) using median of samples from interior rows.
    /// Median is robust to outliers from rounded window corners and photo bleed.
    private static func detectBackgroundColor(
        pixels: [UInt8], width: Int, rowStart: Int, rowEnd: Int, bytesPerRow: Int
    ) -> (UInt8, UInt8, UInt8) {
        var rValues: [UInt8] = []
        var gValues: [UInt8] = []
        var bValues: [UInt8] = []

        let zoneHeight = rowEnd - rowStart
        // Sample interior rows at 25%, 50%, 75% to cover the zone
        let sampleRows = [
            rowStart + zoneHeight / 4,
            rowStart + zoneHeight / 2,
            rowStart + zoneHeight * 3 / 4,
        ]
        // Sample a stripe of columns at 1/3 and 2/3 of width (center band),
        // avoiding both edge corners and icon positions at the very center.
        let thirdWidth = width / 3
        let sampleCols = [
            thirdWidth - 2, thirdWidth - 1, thirdWidth, thirdWidth + 1,
            thirdWidth * 2 - 2, thirdWidth * 2 - 1, thirdWidth * 2, thirdWidth * 2 + 1,
        ]
        for row in sampleRows {
            guard row >= rowStart && row < rowEnd else { continue }
            for col in sampleCols {
                guard col >= 0 && col < width else { continue }
                let offset = row * bytesPerRow + col * 4
                rValues.append(pixels[offset])
                gValues.append(pixels[offset + 1])
                bValues.append(pixels[offset + 2])
            }
        }

        guard !rValues.isEmpty else { return (0, 0, 0) }
        rValues.sort()
        gValues.sort()
        bValues.sort()
        let mid = rValues.count / 2
        return (rValues[mid], gValues[mid], bValues[mid])
    }

    /// Check if a pixel differs from the background by more than the threshold.
    private static func differsByThreshold(
        _ pixels: [UInt8], at offset: Int,
        background: (UInt8, UInt8, UInt8)
    ) -> Bool {
        let dr = abs(Int(pixels[offset]) - Int(background.0))
        let dg = abs(Int(pixels[offset + 1]) - Int(background.1))
        let db = abs(Int(pixels[offset + 2]) - Int(background.2))
        let threshold = Int(EnvConfig.iconColorThreshold)
        return dr > threshold
            || dg > threshold
            || db > threshold
    }

    /// Identify rows within the zone where most pixels match the background color.
    /// Returns an array of row indices that belong to the bar (not content/photos).
    private static func findBarRows(
        pixels: [UInt8], width: Int, rowStart: Int, rowEnd: Int,
        bytesPerRow: Int, background: (UInt8, UInt8, UInt8)
    ) -> [Int] {
        // Sample a subset of columns for efficiency (every 4th pixel, inset from edges)
        let inset = min(EnvConfig.iconCornerInsetPixels, width / 4)
        let sampleCols = Array(stride(from: inset, to: width - inset, by: 4))

        guard !sampleCols.isEmpty else { return [] }
        let sampleCount = sampleCols.count

        var barRows: [Int] = []
        let threshold = Int(Double(sampleCount) * EnvConfig.iconBarRowBgFraction)

        for row in rowStart..<rowEnd {
            var bgCount = 0
            for col in sampleCols {
                let offset = row * bytesPerRow + col * 4
                if !differsByThreshold(pixels, at: offset, background: background) {
                    bgCount += 1
                }
            }
            if bgCount >= threshold {
                barRows.append(row)
            }
        }

        return barRows
    }

    /// Find the vertical centroid of foreground pixels in a column range.
    /// Returns the centroid in full-image pixel coordinates (not relative to the zone).
    private static func findVerticalCentroid(
        pixels: [UInt8], xStart: Int, xEnd: Int,
        rows: [Int], bytesPerRow: Int,
        background: (UInt8, UInt8, UInt8)
    ) -> Double {
        var weightedSum = 0.0
        var totalWeight = 0.0

        for row in rows {
            for x in xStart..<xEnd {
                let offset = row * bytesPerRow + x * 4
                if differsByThreshold(pixels, at: offset, background: background) {
                    weightedSum += Double(row)
                    totalWeight += 1.0
                }
            }
        }

        guard totalWeight > 0, let first = rows.first, let last = rows.last else {
            return 0
        }
        return totalWeight > 0 ? weightedSum / totalWeight : Double(first + last) / 2.0
    }

    /// Apply a box filter (moving average) to smooth a projection array.
    private static func boxFilter(_ values: [Int], windowSize: Int) -> [Int] {
        guard values.count >= windowSize else { return values }
        let halfWindow = windowSize / 2
        var result = [Int](repeating: 0, count: values.count)

        for i in 0..<values.count {
            let start = max(0, i - halfWindow)
            let end = min(values.count - 1, i + halfWindow)
            var sum = 0
            for j in start...end {
                sum += values[j]
            }
            result[i] = sum / (end - start + 1)
        }

        return result
    }
}
