// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Draws a coordinate grid overlay on screenshot PNG data for AI coordinate reference.
// ABOUTME: Grid lines appear every 25 points with labeled axes every 50pt; operates in CG pixel space.

import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Draws a labeled coordinate grid on a screenshot so the AI can map visual
/// elements to precise tap coordinates.
public enum GridOverlay {
    /// Points between grid lines in the mirroring window's coordinate space.
    public static let gridSpacing: CGFloat = 25.0
    /// Alpha for grid lines — subtle but visible on both light and dark backgrounds.
    static let gridLineAlpha: CGFloat = 0.3
    /// Font size in points for coordinate labels (scaled for Retina internally).
    static let gridLabelFontSize: CGFloat = 8.0
    /// Show coordinate labels every N grid lines to reduce clutter at high density.
    static let labelEveryN: Int = 2

    /// Overlay a coordinate grid on raw PNG data.
    ///
    /// - Parameters:
    ///   - pngData: Original screenshot as PNG bytes.
    ///   - windowSize: Size of the mirroring window in points.
    /// - Returns: New PNG data with grid drawn, or `nil` on failure.
    public static func addOverlay(to pngData: Data, windowSize: CGSize) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return nil }

        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        let scaleX = CGFloat(pixelWidth) / windowSize.width
        let scaleY = CGFloat(pixelHeight) / windowSize.height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw original image
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Grid line style: white at low alpha, 1px
        guard let gridLineColor = CGColor(
            colorSpace: colorSpace,
            components: [1.0, 1.0, 1.0, gridLineAlpha]
        ) else { return nil }
        ctx.setStrokeColor(gridLineColor)
        ctx.setLineWidth(1.0)

        let spacing = gridSpacing
        let fontSize = gridLabelFontSize * max(scaleX, scaleY)

        // Vertical lines (constant x)
        var lineIndex = 1
        var x = spacing
        while x < windowSize.width {
            let px = x * scaleX
            ctx.move(to: CGPoint(x: px, y: 0))
            ctx.addLine(to: CGPoint(x: px, y: CGFloat(pixelHeight)))
            ctx.strokePath()
            if lineIndex % labelEveryN == 0 {
                drawLabel(
                    "\(Int(x))",
                    in: ctx,
                    at: CGPoint(x: px + 2, y: CGFloat(pixelHeight) - fontSize - 4),
                    fontSize: fontSize
                )
            }
            x += spacing
            lineIndex += 1
        }

        // Horizontal lines (constant y)
        lineIndex = 1
        var y = spacing
        while y < windowSize.height {
            // CG origin is bottom-left; mirroring window origin is top-left.
            let py = CGFloat(pixelHeight) - y * scaleY
            ctx.move(to: CGPoint(x: 0, y: py))
            ctx.addLine(to: CGPoint(x: CGFloat(pixelWidth), y: py))
            ctx.strokePath()
            if lineIndex % labelEveryN == 0 {
                drawLabel(
                    "\(Int(y))",
                    in: ctx,
                    at: CGPoint(x: 4, y: py + 2),
                    fontSize: fontSize
                )
            }
            y += spacing
            lineIndex += 1
        }

        // Encode back to PNG
        guard let resultImage = ctx.makeImage() else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, resultImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    /// Draw a coordinate label at the given point with a semi-transparent
    /// black pill background for readability on any background.
    private static func drawLabel(
        _ text: String,
        in ctx: CGContext,
        at point: CGPoint,
        fontSize: CGFloat
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let textColor = CGColor(
            colorSpace: colorSpace,
            components: [1.0, 1.0, 1.0, 1.0]
        ) else { return }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: textColor,
        ]
        guard let attrString = CFAttributedStringCreate(
            nil, text as CFString, attributes as CFDictionary
        ) else { return }
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        let padding: CGFloat = 2.0
        let pillRect = CGRect(
            x: point.x - padding,
            y: point.y - padding,
            width: bounds.width + padding * 2,
            height: bounds.height + padding * 2
        )

        // Semi-transparent black background pill
        guard let pillColor = CGColor(
            colorSpace: colorSpace,
            components: [0.0, 0.0, 0.0, 0.6]
        ) else { return }
        ctx.setFillColor(pillColor)
        ctx.fill(pillRect)

        // Draw text
        ctx.saveGState()
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
