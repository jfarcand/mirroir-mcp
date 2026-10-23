// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Crops a screenshot PNG to a window-point region and/or downscales it, re-encoding PNG.
// ABOUTME: The screenshot token lever — fewer pixels per frame means fewer vision tokens per frame.

import CoreGraphics
import Foundation
import ImageIO

/// Crops and/or downscales a captured screenshot to cut the per-frame vision
/// token cost (image tokens scale with pixel count). Pure transform: PNG in,
/// PNG out. Distinct from `ImageResizer`, which scales to a fixed target width
/// for the vision describer and reports coordinate scale factors; this one
/// takes a caller-supplied region (in window points) and a scale factor and
/// returns only the re-encoded bytes.
enum ScreenshotRegionScaler {

    /// Crop `pngData` to `region` (in window points, top-left origin — the same
    /// coordinate space as `describe_screen` and tap coordinates) and/or scale
    /// the result by `scale` (0 < scale <= 1). Either may be nil to skip that
    /// step; both nil returns the original bytes unchanged.
    ///
    /// - Parameters:
    ///   - pngData: the captured screenshot as PNG (typically Retina pixels).
    ///   - windowSize: the mirror window size in points, used to convert the
    ///     point-space `region` into the PNG's pixel space.
    ///   - region: sub-rectangle to keep, in window points; nil keeps the whole
    ///     frame. Clamped to the image bounds.
    ///   - scale: output scale factor in (0, 1]; nil or 1 keeps full resolution.
    /// - Returns: the transformed PNG, or nil on decode/encode failure.
    static func transform(
        pngData: Data,
        windowSize: CGSize,
        region: CGRect?,
        scale: Double?
    ) -> Data? {
        if region == nil, scale == nil { return pngData }

        guard let imageSource = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return nil }

        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        guard pixelWidth > 0, pixelHeight > 0,
              windowSize.width > 0, windowSize.height > 0
        else { return nil }

        // The PNG is in pixels; the region is in window points. Derive the
        // points-to-pixels ratio from the actual decoded width (same rule the
        // OCR/grid code uses: pixelWidth / windowWidth).
        let backingScale = Double(pixelWidth) / Double(windowSize.width)

        let cropped: CGImage
        if let region {
            let x = max(0.0, min(region.origin.x * backingScale, Double(pixelWidth)))
            let y = max(0.0, min(region.origin.y * backingScale, Double(pixelHeight)))
            let w = max(1.0, min(region.size.width * backingScale, Double(pixelWidth) - x))
            let h = max(1.0, min(region.size.height * backingScale, Double(pixelHeight) - y))
            guard let sub = cgImage.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else {
                return nil
            }
            cropped = sub
        } else {
            cropped = cgImage
        }

        let clampedScale = scale.map { max(0.01, min(1.0, $0)) } ?? 1.0
        if clampedScale == 1.0 {
            return encodePNG(cropped)
        }

        let outWidth = max(1, Int((Double(cropped.width) * clampedScale).rounded()))
        let outHeight = max(1, Int((Double(cropped.height) * clampedScale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: outWidth,
            height: outHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))

        guard let scaled = context.makeImage() else { return nil }
        return encodePNG(scaled)
    }

    /// Encode a CGImage as PNG data.
    private static func encodePNG(_ image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
