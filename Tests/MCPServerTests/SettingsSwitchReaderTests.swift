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
// ABOUTME: Tests for SettingsSwitchReader on rows drawn with the colors measured on an iPhone 16 (iOS 27).
// ABOUTME: A green track reads on, a grey track off, a chevron row or text no switch.

import XCTest
import CoreGraphics
@testable import mirroir_mcp

final class SettingsSwitchReaderTests: XCTestCase {

    private let size = CGSize(width: 410, height: 60)
    private let rowY = 30.0
    private let scale = 2

    /// A white row, at 2x, with `fills` (x range in points, RGB) drawn across its middle.
    private func row(_ fills: [(ClosedRange<Int>, (CGFloat, CGFloat, CGFloat))]) -> CGImage {
        let width = Int(size.width) * scale, height = Int(size.height) * scale
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (xs, rgb) in fills {
            context.setFillColor(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
            context.fill(CGRect(x: xs.lowerBound * scale, y: 15 * scale,
                                width: (xs.upperBound - xs.lowerBound) * scale, height: 30 * scale))
        }
        return context.makeImage()!
    }

    func testAGreenTrackIsOn() {
        let reading = SettingsSwitchReader.read(rowY: rowY, image: row([(300 ... 334, (55, 199, 89))]),
                                                windowSize: size)
        XCTAssertEqual(reading.state, .on)
        XCTAssertEqual(Double(reading.center?.x ?? 0), 317, accuracy: 1)
    }

    func testAGreyTrackIsOff() {
        let reading = SettingsSwitchReader.read(rowY: rowY, image: row([(346 ... 370, (197, 197, 199))]),
                                                windowSize: size)
        XCTAssertEqual(reading.state, .off)
    }

    /// XR, iOS 26: the off track is lighter.
    func testTheIOS26GreyTrackIsOff() {
        let reading = SettingsSwitchReader.read(rowY: rowY, image: row([(364 ... 386, (233, 233, 235))]),
                                                windowSize: size)
        XCTAssertEqual(reading.state, .off)
    }

    /// The page's grey around a row card is not a track.
    func testThePageGreyIsNoSwitch() {
        XCTAssertEqual(SettingsSwitchReader.read(rowY: rowY, image: row([(250 ... 400, (242, 242, 247))]),
                                                 windowSize: size).state, .none)
    }

    /// "Treberden >" or "Oui >": short grey strokes, no track.
    func testTextAndAChevronAreNoSwitch() {
        let strokes = stride(from: 290, to: 370, by: 8).map { ($0 ... $0 + 2, (CGFloat(145), CGFloat(145), CGFloat(149))) }
        XCTAssertEqual(SettingsSwitchReader.read(rowY: rowY, image: row(strokes), windowSize: size).state, .none)
    }

    /// Dark appearance was not measured: its track colors read as no switch.
    func testADarkRowIsNoSwitch() {
        let dark = row([(0 ... 410, (28, 28, 30)), (346 ... 370, (57, 57, 61))])
        XCTAssertEqual(SettingsSwitchReader.read(rowY: rowY, image: dark, windowSize: size).state, .none)
    }

    func testASwitchOutsideTheRowIsNotRead() {
        let image = row([(300 ... 334, (55, 199, 89))])
        XCTAssertEqual(SettingsSwitchReader.read(rowY: 5, image: image, windowSize: size).state, .none)
    }
}
