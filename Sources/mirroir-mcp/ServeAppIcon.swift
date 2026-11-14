// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Draws the mirroir robot (website/public/logo-robot.svg) with Core Graphics and writes it as an .icns file.
// ABOUTME: The icon of mirroir's app bundles in the privacy panes and Background Items, and the Claude extension's PNG.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The serve agent's icon, drawn from the shapes of the website's robot logo
/// so the binary carries no image file of its own.
enum ServeAppIcon {

    /// The logo's coordinate space: a 128 x 128 viewBox, y pointing down.
    static let viewBox: CGFloat = 128

    /// Pixel sizes written into the .icns: the ones ImageIO's ICNS writer
    /// keeps (it drops 64 and 1024), which System Settings picks from.
    static let pixelSizes = [16, 32, 128, 256, 512]

    /// An icon file could not be written.
    struct WriteError: Error, LocalizedError {
        let path: String
        var errorDescription: String? { "the icon could not be written to \(path)" }
    }

    private static func color(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    private static let frameTop = color(0x3d2a16)
    private static let frameBottom = color(0x2e1f0f)
    private static let bodyTop = color(0x6bb87a)
    private static let bodyBottom = color(0x3d7a4a)
    private static let eyesTop = color(0x6ee7a0)
    private static let eyesBottom = color(0x34d670)

    /// Fill the current clip with a top-to-bottom gradient over the whole viewBox.
    private static func fillVertical(_ context: CGContext, _ top: CGColor, _ bottom: CGColor) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [top, bottom] as CFArray, locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: viewBox), options: [])
    }

    /// The robot's lines, head outline and smile, as one stroked outline.
    private static func bodyPath() -> CGPath {
        let lines = CGMutablePath()
        for (from, to) in [((44.0, 28.0), (84.0, 28.0)), ((64.0, 28.0), (64.0, 38.0)),
                           ((30.0, 64.0), (20.0, 64.0)), ((98.0, 64.0), (108.0, 64.0))] {
            lines.move(to: CGPoint(x: from.0, y: from.1))
            lines.addLine(to: CGPoint(x: to.0, y: to.1))
        }
        let outline = CGMutablePath()
        outline.addPath(lines.copy(strokingWithWidth: 4.5, lineCap: .round, lineJoin: .round, miterLimit: 10))
        let head = CGPath(roundedRect: CGRect(x: 30, y: 42, width: 68, height: 50),
                          cornerWidth: 16, cornerHeight: 16, transform: nil)
        outline.addPath(head.copy(strokingWithWidth: 5, lineCap: .butt, lineJoin: .round, miterLimit: 10))
        let smile = CGMutablePath()
        smile.move(to: CGPoint(x: 46, y: 76))
        smile.addQuadCurve(to: CGPoint(x: 82, y: 76), control: CGPoint(x: 64, y: 86))
        outline.addPath(smile.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 10))
        outline.addEllipse(in: CGRect(x: 59, y: 20, width: 10, height: 10))
        return outline
    }

    /// The icon at `pixels` x `pixels`, or nil when no bitmap context could be made.
    static func image(pixels: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = CGFloat(pixels) / viewBox
        // The SVG's y axis points down; Core Graphics' points up.
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: scale, y: -scale)

        let frame = CGPath(roundedRect: CGRect(x: 6, y: 6, width: 116, height: 116),
                           cornerWidth: 28, cornerHeight: 28, transform: nil)
        context.saveGState()
        context.addPath(frame)
        context.clip()
        fillVertical(context, frameTop, frameBottom)
        context.restoreGState()
        context.addPath(CGPath(roundedRect: CGRect(x: 10, y: 10, width: 108, height: 108),
                               cornerWidth: 24, cornerHeight: 24, transform: nil))
        context.setFillColor(frameBottom)
        context.fillPath()

        context.saveGState()
        context.addPath(bodyPath())
        context.clip()
        fillVertical(context, bodyTop, bodyBottom)
        context.restoreGState()

        context.saveGState()
        context.addEllipse(in: CGRect(x: 42, y: 52, width: 16, height: 16))
        context.addEllipse(in: CGRect(x: 70, y: 52, width: 16, height: 16))
        context.clip()
        fillVertical(context, eyesTop, eyesBottom)
        context.restoreGState()
        return context.makeImage()
    }

    /// Write the icon at every size in `pixelSizes` as one .icns file.
    ///
    /// - Throws: `WriteError` when a size cannot be drawn or the file cannot be written.
    static func writeICNS(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.icns.identifier as CFString, pixelSizes.count, nil) else {
            throw WriteError(path: path)
        }
        for pixels in pixelSizes {
            guard let image = image(pixels: pixels) else { throw WriteError(path: path) }
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { throw WriteError(path: path) }
    }

    /// Write the icon as one PNG of `pixels` x `pixels`: the image an MCP
    /// Bundle manifest names as its `icon`.
    ///
    /// - Throws: `WriteError` when the icon cannot be drawn or the file cannot be written.
    static func writePNG(to path: String, pixels: Int) throws {
        guard let image = image(pixels: pixels),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WriteError(path: path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WriteError(path: path) }
    }
}
