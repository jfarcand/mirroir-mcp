// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Resizes screenshot PNG data to a target width for vision API payloads.
// ABOUTME: Returns the resized image and a scale factor for mapping coordinates back to window points.

import CoreGraphics
import Foundation
import ImageIO

/// Resizes PNG screenshot data for vision API calls and provides coordinate scaling.
enum ImageResizer {

    /// Result of a resize operation.
    struct ResizeResult {
        /// Resized PNG as raw data.
        let data: Data
        /// Resized PNG as base64-encoded string.
        let base64: String
        /// Scale factor to convert vision-image coordinates back to window points.
        /// Usage: `windowX = visionX * scaleX`, `windowY = visionY * scaleY`.
        let scaleX: Double
        let scaleY: Double
    }

    /// Resize PNG data to a target width, maintaining aspect ratio.
    ///
    /// - Parameters:
    ///   - pngData: Original screenshot as PNG data (typically Retina resolution).
    ///   - targetWidth: Desired width in pixels for the resized image.
    ///   - windowSize: Window size in points (for computing scale factors).
    /// - Returns: The resized image data and coordinate scale factors, or nil on failure.
    static func resize(pngData: Data, targetWidth: Int, windowSize: CGSize) -> ResizeResult? {
        guard let imageSource = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return nil }

        let originalWidth = cgImage.width
        let originalHeight = cgImage.height
        guard originalWidth > 0, originalHeight > 0 else { return nil }

        let aspectRatio = Double(originalHeight) / Double(originalWidth)
        let targetHeight = Int(Double(targetWidth) * aspectRatio)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let resizedImage = context.makeImage() else { return nil }

        // Export as PNG
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, resizedImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let pngResult = mutableData as Data
        let scaleX = Double(windowSize.width) / Double(targetWidth)
        let scaleY = Double(windowSize.height) / Double(targetHeight)

        return ResizeResult(
            data: pngResult,
            base64: pngResult.base64EncodedString(),
            scaleX: scaleX,
            scaleY: scaleY
        )
    }
}
