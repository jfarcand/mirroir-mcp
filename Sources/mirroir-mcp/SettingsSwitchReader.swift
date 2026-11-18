/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Reads whether an iOS Settings switch is on or off from the pixels of the row its label sits in.
// ABOUTME: OCR sees no switch, so its track color decides: green on, grey off, anything else no switch.

import CoreGraphics
import Foundation
import ImageIO

/// The state of the switch in one Settings row (pure transformation).
///
/// OCR reads a row's label but not its switch. The switch is a track at the
/// row's right end: green with the knob on the right when on, grey with the
/// knob on the left when off. Measured in the light appearance on 2026-11-18:
/// on (55, 199, 89) and off (197, 197, 199) on an iPhone 16 (iOS 27, x 300-372
/// of a 410-point row); off (233, 233, 235) on an XR (iOS 26). A track is a run of its color at least
/// `minTrackRunPt` long on the label's line; text strokes give shorter runs.
/// Anything else, a chevron row ("Wi-Fi  Treberden >"), a menu, or the dark
/// appearance this was not measured in, reads as no switch, so nothing is
/// tapped on a guess.
enum SettingsSwitchReader {

    enum State: Equatable {
        case on, off
        /// No switch was found in the row.
        case none
    }

    /// The switch's state and where to tap it, in window points.
    struct Reading: Equatable {
        let state: State
        let center: CGPoint?
    }

    /// The part of the row's width the switch is looked for in.
    static let searchFromFraction = 0.6
    static let searchToFraction = 0.95
    /// The shortest run of track color that counts as a track, in points.
    static let minTrackRunPt = 10.0
    /// Lines read above and below the label's center, in points.
    static let lineOffsetsPt: [Double] = [-4, 0, 4]

    /// The switch in the row of the label at `rowY`, read from `pngBase64`, the
    /// screenshot of a window `windowSize` points wide and tall.
    static func read(rowY: Double, pngBase64: String, windowSize: CGSize) -> Reading {
        guard let data = Data(base64Encoded: pngBase64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return Reading(state: .none, center: nil)
        }
        return read(rowY: rowY, image: image, windowSize: windowSize)
    }

    static func read(rowY: Double, image: CGImage, windowSize: CGSize) -> Reading {
        guard windowSize.width > 0, let pixels = Pixels(image) else { return Reading(state: .none, center: nil) }
        let scale = Double(image.width) / windowSize.width
        let from = Int(windowSize.width * searchFromFraction * scale)
        let to = Int(windowSize.width * searchToFraction * scale)
        let minRun = Int(minTrackRunPt * scale)
        var best: (state: State, run: Int, startX: Int)?
        for offset in lineOffsetsPt {
            let y = Int((rowY + offset) * scale)
            guard y >= 0, y < pixels.height else { continue }
            for state in [State.on, .off] {
                let run = longestRun(in: pixels, y: y, from: from, to: min(to, pixels.width)) {
                    state == .on ? isOnTrack($0) : isOffTrack($0)
                }
                if run.length >= minRun, run.length > (best?.run ?? 0) {
                    best = (state, run.length, run.start)
                }
            }
        }
        guard let best else { return Reading(state: .none, center: nil) }
        // The knob sits beside the track run: on the right when on, the left when off.
        let trackCenter = Double(best.startX) + Double(best.run) / 2
        let center = CGPoint(x: trackCenter / scale, y: rowY)
        return Reading(state: best.state, center: center)
    }

    /// Track green: (55, 199, 89) as measured, with room for compression.
    static func isOnTrack(_ rgb: (Int, Int, Int)) -> Bool {
        let (r, g, b) = rgb
        return g > 150 && g - r > 80 && g - b > 50
    }

    /// Track grey: (197, 197, 199) on iOS 27 and (233, 233, 235) on iOS 26 as
    /// measured; a neutral grey below the row's white (255) and the page's
    /// grey (242, 242, 247), above the labels' darker greys.
    static func isOffTrack(_ rgb: (Int, Int, Int)) -> Bool {
        let (r, g, b) = rgb
        return (185 ... 238).contains(r) && abs(r - g) <= 4 && abs(b - g) <= 6
    }

    private static func longestRun(
        in pixels: Pixels, y: Int, from: Int, to: Int, matching: ((Int, Int, Int)) -> Bool
    ) -> (start: Int, length: Int) {
        var best = (start: 0, length: 0)
        var start = from
        var length = 0
        for x in max(0, from) ..< max(from, to) {
            if matching(pixels.rgb(x: x, y: y)) {
                if length == 0 { start = x }
                length += 1
                if length > best.length { best = (start, length) }
            } else {
                length = 0
            }
        }
        return best
    }

    /// An image rendered to RGBA bytes, top row first.
    private struct Pixels {
        let width: Int
        let height: Int
        private let bytes: [UInt8]

        init?(_ image: CGImage) {
            let width = image.width
            let height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            bytes = buffer
        }

        func rgb(x: Int, y: Int) -> (Int, Int, Int) {
            let index = (y * width + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
        }
    }
}
