// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Reduces a captured PNG frame to its decoded pixel bytes for equality comparison.
// ABOUTME: Lets ScreenCapture detect a settled frame without comparing encoder-dependent PNG bytes.

import CoreGraphics
import Foundation
import ImageIO

/// Reduces an encoded screenshot to a value that compares equal only when the
/// two frames show the same pixels (pure transformation pattern).
///
/// Comparing the PNG bytes directly is not reliable: two encodings of identical
/// pixels can differ, and any metadata the encoder writes changes with every
/// capture. Decoding to raw pixels sidesteps both problems, so a comparison
/// answers the question actually being asked — "has the screen stopped
/// changing?" — rather than "did the encoder emit the same file?".
enum FrameFingerprint {

    /// Decode a PNG frame to its raw pixel bytes.
    ///
    /// Returns `nil` when the data is not a decodable image, in which case the
    /// caller must treat the comparison as inconclusive rather than as a match —
    /// two undecodable frames are not evidence that the screen has settled.
    static func pixels(of png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let provider = image.dataProvider,
              let pixels = provider.data
        else { return nil }
        return pixels as Data
    }

    /// Whether two encoded frames show the same pixels.
    ///
    /// Returns `false` when either frame fails to decode, so an unreadable
    /// capture never counts as "settled".
    static func sameContent(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let left = pixels(of: lhs), let right = pixels(of: rhs) else { return false }
        return left == right
    }

    /// Whether two encoded frames show the same pixels in a band of rows,
    /// given as fractions of the frame height. What changes outside the band
    /// (a status-bar clock, say) does not count.
    ///
    /// Returns `false` when either frame fails to decode or the two differ in
    /// size, so frames that cannot be compared are never taken for the same.
    static func sameRows(_ lhs: Data, _ rhs: Data, band: ClosedRange<Double>) -> Bool {
        guard let left = rows(of: lhs, band: band), let right = rows(of: rhs, band: band) else {
            return false
        }
        return left.width == right.width && left.pixels == right.pixels
    }

    /// The pixel bytes of the rows inside `band`, with the frame's width.
    private static func rows(of png: Data, band: ClosedRange<Double>) -> (width: Int, pixels: Data)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let data = image.dataProvider?.data as Data?,
              image.height > 0 else { return nil }
        let height = Double(image.height)
        let first = max(0, min(image.height, Int((height * band.lowerBound).rounded(.down))))
        let last = max(first, min(image.height, Int((height * band.upperBound).rounded(.up))))
        let range = (first * image.bytesPerRow) ..< min(data.count, last * image.bytesPerRow)
        guard range.lowerBound <= range.upperBound else { return nil }
        return (image.width, data.subdata(in: range))
    }
}
