// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that reset_app drags an App Switcher card only once two reads agree on where it rests.
// ABOUTME: A card read mid-slide, from a lagging frame, or in another window size must never be the drag target.

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
        XCTAssertEqual(result, .success(rest(321)))
        XCTAssertEqual(switcher.readCount, 3)
    }

    /// A card already at rest is dragged after the confirming second read.
    func testCardAtRestNeedsTwoAgreeingReads() {
        let switcher = SwitcherFrames(frames: [Self.switcher(horlogeLabelX: 321)])
        XCTAssertEqual(locate(with: switcher), .success(rest(321)))
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

    // MARK: - Rotation

    /// A switcher opened while the mirror rotates out of portrait: the first
    /// read is portrait, the window then turns landscape. Two reads agree only
    /// within one window size, and the card carries the size it was read in.
    func testReadsAgreeOnlyWithinOneWindowSize() {
        let landscape = CGSize(width: 942, height: 430)
        // The landscape switcher as read on the XR: labels near the top
        // (y≈76), the just-launched card at the right edge.
        let landscapeFrame = [
            TapPoint(text: "Brave", tapX: 322, tapY: 79, confidence: 1),
            TapPoint(text: "Horloge", tapX: 823, tapY: 76, confidence: 1),
        ]
        let switcher = SwitcherFrames(frames: [
            Self.switcher(horlogeLabelX: 321), landscapeFrame, landscapeFrame,
        ])
        var sizes = [window, landscape, landscape]
        let result = AppSwitcherDismissal.locateRestingCard(
            appName: "Horloge", appElements: [], describer: switcher,
            windowSize: { sizes.count > 1 ? sizes.removeFirst() : sizes[0] },
            pauseUs: 0, sleep: { _ in })
        XCTAssertEqual(result, .success(.init(x: 823, windowSize: landscape)))
        XCTAssertEqual(switcher.readCount, 3, "the portrait read cannot confirm a landscape one")
    }

    /// A read the window resized across comes back nil: the locator reads
    /// again instead of failing.
    func testADroppedReadIsReadAgain() {
        let switcher = SwitcherFrames(frames: [nil, Self.switcher(horlogeLabelX: 321)])
        XCTAssertEqual(locate(with: switcher), .success(rest(321)))
        XCTAssertEqual(switcher.readCount, 3)
    }

    /// Reads that never come back fail closed as unreadable.
    func testNoReadEverFailsClosed() {
        let switcher = SwitcherFrames(frames: [nil])
        XCTAssertEqual(locate(with: switcher), .failure(.unreadable))
        XCTAssertEqual(switcher.readCount, AppSwitcherDismissal.maxRestReads)
    }

    // MARK: - Helpers

    private func rest(_ x: Double) -> AppSwitcherDismissal.RestingCard {
        .init(x: x, windowSize: window)
    }

    private func locate(
        with switcher: SwitcherFrames
    ) -> Result<AppSwitcherDismissal.RestingCard, AppSwitcherDismissal.CardLocateFailure> {
        AppSwitcherDismissal.locateRestingCard(
            appName: "Horloge", appElements: [], describer: switcher,
            windowSize: { self.window }, pauseUs: 0, sleep: { _ in })
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
/// A nil frame is a read that came back empty-handed (the window resized
/// across it).
private final class SwitcherFrames: ScreenDescribing, @unchecked Sendable {
    private let frames: [[TapPoint]?]
    private(set) var readCount = 0

    init(frames: [[TapPoint]?]) { self.frames = frames }

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
        let elements = frames[min(readCount, frames.count - 1)]
        readCount += 1
        return elements.map { ScreenDescriber.DescribeResult(elements: $0, screenshotBase64: "") }
    }
}
