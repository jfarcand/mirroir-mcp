// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests WindowStableDescriber: a read the window resized across (a rotation) is dropped,
// ABOUTME: a read in one window size passes through unchanged.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

final class WindowStableDescriberTests: XCTestCase {

    private let portrait = CGSize(width: 430, height: 942)
    private let landscape = CGSize(width: 942, height: 430)

    /// A describer whose read ends after the window took `sizeAfterRead`, as
    /// the mirror does when the device rotates during the capture.
    private final class RotatingDescriber: ScreenDescribing, @unchecked Sendable {
        let bridge: StubBridge
        var sizeAfterRead: CGSize?
        private(set) var reads = 0

        init(bridge: StubBridge) { self.bridge = bridge }

        func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
            reads += 1
            if let size = sizeAfterRead, let info = bridge.windowInfo {
                bridge.windowInfo = WindowInfo(
                    windowID: info.windowID, position: info.position, size: size, pid: info.pid)
            }
            return ScreenDescriber.DescribeResult(
                elements: [TapPoint(text: "Brawl Stars", tapX: 615, tapY: 337, confidence: 1)],
                screenshotBase64: "")
        }
    }

    private func bridge(size: CGSize) -> StubBridge {
        let bridge = StubBridge()
        bridge.windowInfo = WindowInfo(windowID: 1, position: .zero, size: size, pid: 1)
        return bridge
    }

    func testAReadTheWindowRotatedAcrossIsDropped() {
        let bridge = bridge(size: landscape)
        let rotating = RotatingDescriber(bridge: bridge)
        rotating.sizeAfterRead = portrait
        let describer = WindowStableDescriber(wrapping: rotating, bridge: bridge)

        XCTAssertNil(describer.describe(settleTimeoutUs: 0),
                     "landscape tap points must not reach a portrait window")
        XCTAssertEqual(rotating.reads, 1)
    }

    func testTheNextReadInOneOrientationPassesThrough() {
        let bridge = bridge(size: landscape)
        let rotating = RotatingDescriber(bridge: bridge)
        rotating.sizeAfterRead = portrait
        let describer = WindowStableDescriber(wrapping: rotating, bridge: bridge)
        _ = describer.describe(settleTimeoutUs: 0)

        let settled = describer.describe(settleTimeoutUs: 0)

        XCTAssertEqual(settled?.elements.map(\.text), ["Brawl Stars"])
        XCTAssertEqual(rotating.reads, 2)
    }

    func testInputSimulationReadsThroughTheStableDescriber() {
        let bridge = bridge(size: portrait)
        let rotating = RotatingDescriber(bridge: bridge)
        rotating.sizeAfterRead = landscape
        let input = InputSimulation(bridge: bridge, keyboardLayout: .usQWERTY,
                                    pasteVerifier: rotating)

        XCTAssertNil(input.pasteVerifier?.describe(settleTimeoutUs: 0),
                     "launch_app and paste checks read through the rotation guard")
    }
}
