// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that reset_app drags an App Switcher card only once two reads agree on where it rests.
// ABOUTME: A card read mid-slide, or from a lagging frame, must never be the drag target.

import CoreGraphics
import HelperLib
import XCTest
@testable import mirroir_mcp

final class AppSwitcherRestingCardTests: XCTestCase {

    private let window = CGSize(width: 430, height: 942)

    /// The Horloge card read centered (x≈217) on the first frame, then at its
    /// resting slot (label x=321): the drag targets the slot, never the
    /// centered read, which lies over the neighboring card.
    func testCardStillSlidingIsReadUntilItRests() {
        let switcher = SwitcherFrames(frames: [
            Self.switcher(horlogeLabelX: 217),
            Self.switcher(horlogeLabelX: 321),
            Self.switcher(horlogeLabelX: 321),
        ])
        let result = locate(with: switcher)
        XCTAssertEqual(result, .success(321))
        XCTAssertEqual(switcher.readCount, 3)
    }

    /// A card already at rest is dragged after the confirming second read.
    func testCardAtRestNeedsTwoAgreeingReads() {
        let switcher = SwitcherFrames(frames: [Self.switcher(horlogeLabelX: 321)])
        XCTAssertEqual(locate(with: switcher), .success(321))
        XCTAssertEqual(switcher.readCount, 2)
    }

    /// A card that moves on every read is never dragged.
    func testCardThatNeverHoldsStillFailsClosed() {
        let switcher = SwitcherFrames(frames: [
            Self.switcher(horlogeLabelX: 200),
            Self.switcher(horlogeLabelX: 240),
            Self.switcher(horlogeLabelX: 280),
            Self.switcher(horlogeLabelX: 320),
        ])
        XCTAssertEqual(locate(with: switcher), .failure(.neverSettled))
        XCTAssertEqual(switcher.readCount, AppSwitcherDismissal.maxRestReads)
    }

    /// A switcher that never shows the card fails closed as not found.
    func testCardNeverShownFailsClosed() {
        let switcher = SwitcherFrames(frames: [[
            TapPoint(text: "Roblox", tapX: 154, tapY: 150, confidence: 1),
        ]])
        XCTAssertEqual(locate(with: switcher), .failure(.notFound))
    }

    /// An empty switcher read stops at once.
    func testEmptySwitcherFailsClosed() {
        let switcher = SwitcherFrames(frames: [[]])
        XCTAssertEqual(locate(with: switcher), .failure(.empty))
        XCTAssertEqual(switcher.readCount, 1)
    }

    // MARK: - Helpers

    private func locate(with switcher: SwitcherFrames) -> Result<Double, AppSwitcherDismissal.CardLocateFailure> {
        AppSwitcherDismissal.locateRestingCard(
            appName: "Horloge", appElements: [], describer: switcher,
            windowSize: window, pauseUs: 0, sleep: { _ in })
    }

    /// Switcher OCR with the Roblox card label on the left and the Horloge
    /// label at `horlogeLabelX`, both in the label band.
    private static func switcher(horlogeLabelX: Double) -> [TapPoint] {
        [
            TapPoint(text: "Roblox", tapX: 154, tapY: 150, confidence: 1),
            TapPoint(text: "Horloge", tapX: horlogeLabelX, tapY: 147, confidence: 1),
            TapPoint(text: "Alarmes", tapX: horlogeLabelX - 26, tapY: 247, confidence: 1),
        ]
    }
}

/// Test double: returns switcher frames in order, repeating the last one —
/// the mirrored App Switcher as successive reads see it.
private final class SwitcherFrames: ScreenDescribing, @unchecked Sendable {
    private let frames: [[TapPoint]]
    private(set) var readCount = 0

    init(frames: [[TapPoint]]) { self.frames = frames }

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
        let elements = frames[min(readCount, frames.count - 1)]
        readCount += 1
        return ScreenDescriber.DescribeResult(elements: elements, screenshotBase64: "")
    }
}
