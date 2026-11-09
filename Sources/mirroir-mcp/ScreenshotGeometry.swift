// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Says where a returned screenshot sits in the window's point space: its pixel size, the points it shows, and the factor between them.
// ABOUTME: Converts a point read off an image back to a window point, so an agent never has to guess a Retina factor.

import CoreGraphics
import Foundation
import ImageIO

/// Where a returned screenshot sits in the window's point space.
///
/// `tap` takes window points and a screenshot is in pixels. The factor
/// between them is not fixed: it follows the display's backing scale, the
/// `scale` argument, and the `region` crop. So the geometry is reported with
/// every screenshot instead of being assumed.
struct ScreenshotGeometry: Equatable, Sendable {
    /// Width and height of the PNG that was returned, in pixels.
    let pixelSize: CGSize
    /// The window's size, in points.
    let windowSize: CGSize
    /// The window points the image covers: the clamped region, or the whole window.
    let shownRect: CGRect

    /// Image pixels per window point.
    var pixelsPerPoint: Double {
        shownRect.width > 0 ? pixelSize.width / shownRect.width : 0
    }

    /// The geometry of `png` as returned for a window of `windowSize`, cropped
    /// to `region` (window points) when one was asked for. Nil when the PNG's
    /// header cannot be read or the window has no size.
    static func of(png: Data, windowSize: CGSize, region: CGRect?) -> ScreenshotGeometry? {
        guard windowSize.width > 0, windowSize.height > 0,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0 else { return nil }
        return ScreenshotGeometry(
            pixelSize: CGSize(width: width, height: height), windowSize: windowSize,
            shownRect: shownRect(region: region, windowSize: windowSize))
    }

    /// The part of the window a `region` crop shows: the region clamped to the
    /// window, the way the crop itself is, or the whole window without one.
    static func shownRect(region: CGRect?, windowSize: CGSize) -> CGRect {
        guard let region else { return CGRect(origin: .zero, size: windowSize) }
        let x = max(0, min(region.origin.x, windowSize.width))
        let y = max(0, min(region.origin.y, windowSize.height))
        return CGRect(x: x, y: y,
                      width: max(minimumShownPoints, min(region.width, windowSize.width - x)),
                      height: max(minimumShownPoints, min(region.height, windowSize.height - y)))
    }

    /// The smallest side a shown region is given, so a degenerate crop still divides.
    static let minimumShownPoints: Double = 1

    /// The window point for a point read off an image of `imageSize` that
    /// shows `shownRect`. Proportional, so it holds for any backing scale and
    /// for an image the client resized, as long as `imageSize` is the size the
    /// point was read in. One scale, taken from the width, serves both axes:
    /// it is the scale `describe_screen` places text with, so a point read off
    /// an image lands where the same element's listed point does, even when a
    /// capture is taller than the window it shows.
    static func windowPoint(imagePoint: CGPoint, imageSize: CGSize, shownRect: CGRect) -> CGPoint {
        let pointsPerPixel = shownRect.width / imageSize.width
        return CGPoint(x: shownRect.origin.x + imagePoint.x * pointsPerPixel,
                       y: shownRect.origin.y + imagePoint.y * pointsPerPixel)
    }

    /// The sentence sent with the image: what it shows, and how to tap a point seen in it.
    var summary: String {
        let pixels = "\(Self.whole(pixelSize.width))x\(Self.whole(pixelSize.height))"
        let window = "\(Self.whole(windowSize.width))x\(Self.whole(windowSize.height)) pt window"
        let factor = "\(Self.compact(pixelsPerPoint)) px per point"
        let imageSize = "image_size [\(Self.whole(pixelSize.width)), \(Self.whole(pixelSize.height))]"
        let intro = "tap takes points, not pixels: to tap something seen here, pass its position "
            + "in this image as x and y with"
        guard shownRect != CGRect(origin: .zero, size: windowSize) else {
            return "Screenshot: \(pixels) px showing the whole \(window) (\(factor)). \(intro) \(imageSize)."
        }
        let shown = "x \(Self.whole(shownRect.minX))-\(Self.whole(shownRect.maxX)), "
            + "y \(Self.whole(shownRect.minY))-\(Self.whole(shownRect.maxY))"
        let region = "image_region [\(Self.whole(shownRect.minX)), \(Self.whole(shownRect.minY)), "
            + "\(Self.whole(shownRect.width)), \(Self.whole(shownRect.height))]"
        return "Screenshot: \(pixels) px showing window points \(shown) of the \(window) (\(factor)). "
            + "\(intro) \(imageSize) and \(region)."
    }

    /// Formatted, not converted: `Int(_:)` traps on a value no integer holds.
    static func whole(_ value: Double) -> String { String(format: "%.0f", value.rounded()) }

    /// A factor with at most two decimals and no trailing zeros: "2", "1.5".
    private static func compact(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
