// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Detects a blank (uniform or near-uniform) captured frame, e.g. mid-rotation or mid-launch.
// ABOUTME: Lets the describers report a transitioning screen instead of describing an empty fill.

import CoreGraphics
import Foundation
import HelperLib
import ImageIO

/// Decides whether a captured frame shows nothing but a solid fill
/// (pure transformation pattern).
///
/// The mirroring window shows a solid black (or white) frame while the device
/// rotates, launches an app, or swaps a game scene. Describing that frame is
/// worse than useless on the vision path — the model answers "blank screen"
/// and the call is billed in full — so the describers check first.
enum BlankFrameDetector {

    /// Whether `image` is a uniform or near-uniform frame.
    ///
    /// The frame is downsampled to a `sampleSize`-square grid; a sample counts as
    /// content when its luminance sits more than `luminanceTolerance` from the
    /// grid's median luminance. The frame is blank when the content fraction is
    /// at most `maxContentFraction`. An image that cannot be rendered is never
    /// reported blank: an unreadable frame is not evidence of an empty screen.
    static func isBlank(
        _ image: CGImage,
        sampleSize: Int = EnvConfig.blankFrameSampleSize,
        luminanceTolerance: Int = EnvConfig.blankFrameLuminanceTolerance,
        maxContentFraction: Double = EnvConfig.blankFrameMaxContentFraction
    ) -> Bool {
        guard let fraction = contentFraction(
            image, sampleSize: sampleSize, luminanceTolerance: luminanceTolerance
        ) else { return false }
        return fraction <= maxContentFraction
    }

    /// Fraction (0-1) of grid samples whose luminance sits more than
    /// `luminanceTolerance` from the median, or nil when `image` cannot be rendered.
    static func contentFraction(
        _ image: CGImage,
        sampleSize: Int = EnvConfig.blankFrameSampleSize,
        luminanceTolerance: Int = EnvConfig.blankFrameLuminanceTolerance
    ) -> Double? {
        guard let luminances = sampleLuminances(of: image, sampleSize: sampleSize),
              !luminances.isEmpty
        else { return nil }

        let median = luminances.sorted()[luminances.count / 2]
        let contentCount = luminances.filter { abs($0 - median) > luminanceTolerance }.count
        return Double(contentCount) / Double(luminances.count)
    }

    /// Whether the encoded frame `pngData` is blank. Undecodable data is not blank.
    static func isBlank(pngData: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        return isBlank(image)
    }

    /// Render `image` into a `sampleSize`-square RGBA grid and return the
    /// Rec. 601 luminance (0-255) of every sample.
    private static func sampleLuminances(of image: CGImage, sampleSize: Int) -> [Int]? {
        guard sampleSize > 0 else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * sampleSize)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleSize, height: sampleSize,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            return true
        }
        guard drawn else { return nil }

        return stride(from: 0, to: pixels.count, by: bytesPerPixel).map { offset in
            let weighted = rec601Weights.red * Int(pixels[offset])
                + rec601Weights.green * Int(pixels[offset + 1])
                + rec601Weights.blue * Int(pixels[offset + 2])
            return weighted / rec601Weights.scale
        }
    }

    /// ITU-R BT.601 luma weights in thousandths, so luminance stays integer math.
    private static let rec601Weights = (red: 299, green: 587, blue: 114, scale: 1000)
}
