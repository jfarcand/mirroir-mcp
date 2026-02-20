// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Detects the iOS content rectangle within an iPhone Mirroring window screenshot.
// ABOUTME: Scans from edges inward to find non-dark pixels, returning the content bounds in pixels.

import CoreGraphics

/// Detects the actual iOS content area within the iPhone Mirroring window.
///
/// In "Larger" display mode, the macOS window is bigger than the iOS content,
/// which renders at 1:1 point mapping from the top-left with dark borders on the
/// right and bottom. This detector finds those borders by scanning scanlines from
/// the edges inward, returning the content rectangle in pixel coordinates.
///
/// When content fills the entire window (Smaller/Actual Size modes), the returned
/// rectangle equals the full image bounds — making the correction an identity transform.
public enum ContentBoundsDetector {
    /// Brightness threshold: pixels with all RGB channels at or below this value
    /// are considered "dark" (border). Value chosen to tolerate slight compression
    /// artifacts while catching real content edges.
    static var brightnessThreshold: UInt8 { EnvConfig.brightnessThreshold }

    /// Fractions of the image dimension at which scanlines are sampled.
    /// Using 30-70% avoids edge artifacts while covering the content interior.
    static let scanlineFractions: [Double] = [0.3, 0.4, 0.5, 0.6, 0.7]

    /// Detect the content rectangle within a screenshot image.
    ///
    /// - Parameter image: The raw screenshot as a `CGImage` (in pixel coordinates).
    /// - Returns: A `CGRect` in top-down pixel coordinates representing the content area.
    ///           Returns the full image rect if no borders are detected.
    public static func detect(image: CGImage) -> CGRect {
        let width = image.width
        let height = image.height
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)

        // Render the image into a raw RGBA buffer for pixel access.
        // CGContext pixel buffer stores rows top-to-bottom: buffer row 0 = image top.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return fullRect }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // All coordinates are top-down: row 0 = top of image, y increases downward.

        // --- Horizontal scanlines: find left/right content edges ---
        var maxContentRight = 0
        var minContentLeft = width
        for fraction in scanlineFractions {
            let row = Int(Double(height) * fraction)
            guard row >= 0 && row < height else { continue }

            let rightEdge = scanRowFromRight(row: row, width: width, bytesPerRow: bytesPerRow, pixels: pixelData)
            maxContentRight = max(maxContentRight, rightEdge)

            let leftEdge = scanRowFromLeft(row: row, width: width, bytesPerRow: bytesPerRow, pixels: pixelData)
            minContentLeft = min(minContentLeft, leftEdge)
        }

        // --- Vertical scanlines: find top/bottom content edges ---
        var minContentTop = height
        var maxContentBottom = 0
        for fraction in scanlineFractions {
            let x = Int(Double(width) * fraction)
            guard x >= 0 && x < width else { continue }

            let topEdge = scanColFromTop(col: x, height: height, bytesPerRow: bytesPerRow, pixels: pixelData)
            minContentTop = min(minContentTop, topEdge)

            let bottomEdge = scanColFromBottom(col: x, height: height, bytesPerRow: bytesPerRow, pixels: pixelData)
            maxContentBottom = max(maxContentBottom, bottomEdge)
        }

        // If detection found no content at all (e.g., all-black image), return full rect
        if maxContentRight == 0 || maxContentBottom == 0 {
            return fullRect
        }
        if minContentLeft >= maxContentRight || minContentTop >= maxContentBottom {
            return fullRect
        }

        let contentWidth = maxContentRight - minContentLeft
        let contentHeight = maxContentBottom - minContentTop

        return CGRect(x: minContentLeft, y: minContentTop, width: contentWidth, height: contentHeight)
    }

    // MARK: - Scanline helpers

    /// Scan a row from the right edge inward; return the x+1 of the first non-dark pixel.
    private static func scanRowFromRight(row: Int, width: Int, bytesPerRow: Int, pixels: [UInt8]) -> Int {
        let rowOffset = row * bytesPerRow
        for x in stride(from: width - 1, through: 0, by: -1) {
            let offset = rowOffset + x * 4
            if isNonDark(pixels, at: offset) {
                return x + 1
            }
        }
        return 0
    }

    /// Scan a row from the left edge inward; return the x of the first non-dark pixel.
    private static func scanRowFromLeft(row: Int, width: Int, bytesPerRow: Int, pixels: [UInt8]) -> Int {
        let rowOffset = row * bytesPerRow
        for x in 0..<width {
            let offset = rowOffset + x * 4
            if isNonDark(pixels, at: offset) {
                return x
            }
        }
        return width
    }

    /// Scan a column from the top (row 0) downward; return the row of the first non-dark pixel.
    private static func scanColFromTop(col: Int, height: Int, bytesPerRow: Int, pixels: [UInt8]) -> Int {
        for row in 0..<height {
            let offset = row * bytesPerRow + col * 4
            if isNonDark(pixels, at: offset) {
                return row
            }
        }
        return height
    }

    /// Scan a column from the bottom (row height-1) upward;
    /// return row+1 of the first non-dark pixel found from the bottom.
    private static func scanColFromBottom(col: Int, height: Int, bytesPerRow: Int, pixels: [UInt8]) -> Int {
        for row in stride(from: height - 1, through: 0, by: -1) {
            let offset = row * bytesPerRow + col * 4
            if isNonDark(pixels, at: offset) {
                return row + 1
            }
        }
        return 0
    }

    /// Check if the pixel at the given byte offset is non-dark (any channel > threshold).
    private static func isNonDark(_ pixels: [UInt8], at offset: Int) -> Bool {
        pixels[offset] > brightnessThreshold
            || pixels[offset + 1] > brightnessThreshold
            || pixels[offset + 2] > brightnessThreshold
    }
}
