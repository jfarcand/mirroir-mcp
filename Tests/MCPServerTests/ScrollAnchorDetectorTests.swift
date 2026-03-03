// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ScrollAnchorDetector: anchor matching and scroll offset computation.
// ABOUTME: Verifies that fixed UI elements (tab bars, nav bars) are detected as scroll anchors.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ScrollAnchorDetectorTests: XCTestCase {

    private let windowHeight: Double = 890

    private func tap(_ text: String, x: Double = 205, y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    // MARK: - Anchor Finding

    func testFindAnchorsMatchesTabBarItems() {
        // Tab bar items appear at the same position in both viewports
        let previous = [
            tap("Home", x: 56, y: 860),
            tap("Search", x: 158, y: 860),
            tap("Profile", x: 354, y: 860),
            tap("Content A", y: 300),
        ]
        let current = [
            tap("Home", x: 56, y: 860),
            tap("Search", x: 158, y: 860),
            tap("Profile", x: 354, y: 860),
            tap("Content B", y: 300),
        ]

        let matches = ScrollAnchorDetector.findAnchors(
            previous: previous, current: current, windowHeight: windowHeight
        )

        XCTAssertEqual(matches.count, 3,
            "Should match all 3 tab bar items as anchors")
        XCTAssertTrue(matches.allSatisfy { $0.scrollOffset == 0.0 },
            "Tab bar items don't move, so offset should be 0")
    }

    func testFindAnchorsNoOverlapReturnsEmpty() {
        let previous = [
            tap("Item A", y: 300),
            tap("Item B", y: 400),
        ]
        let current = [
            tap("Item C", y: 300),
            tap("Item D", y: 400),
        ]

        let matches = ScrollAnchorDetector.findAnchors(
            previous: previous, current: current, windowHeight: windowHeight
        )

        XCTAssertTrue(matches.isEmpty,
            "No matching text in anchor zones should return empty")
    }

    func testAnchorDetectionIgnoresScrollingContent() {
        // Mid-screen elements with same text but at different positions
        let previous = [
            tap("Content", y: 400),
            tap("Settings", y: 100),
        ]
        let current = [
            tap("Content", y: 200),
            tap("Settings", y: 100),
        ]

        let matches = ScrollAnchorDetector.findAnchors(
            previous: previous, current: current, windowHeight: windowHeight
        )

        // "Content" at y=400 is mid-screen (not in anchor zones), should be excluded
        // "Settings" at y=100 is in top zone, should match
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.text, "Settings")
    }

    // MARK: - Offset Computation

    func testComputeOffsetFromSingleAnchor() throws {
        let previous = [
            tap("Title", y: 100),
            tap("Content A", y: 400),
        ]
        let current = [
            tap("Title", y: 100),
            tap("Content B", y: 400),
        ]

        let result = ScrollAnchorDetector.computeOffset(
            previous: previous, current: current,
            windowHeight: windowHeight, minAnchors: 1
        )

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.scrollOffset, 0.0, accuracy: 0.01,
            "Nav bar title at same position means zero offset")
        XCTAssertEqual(unwrapped.anchorCount, 1)
    }

    func testComputeOffsetMedianMultipleAnchors() throws {
        // Three anchors with slightly different measured offsets (OCR noise)
        let previous = [
            tap("Home", x: 56, y: 860),
            tap("Search", x: 158, y: 862),
            tap("Profile", x: 354, y: 858),
        ]
        let current = [
            tap("Home", x: 56, y: 860),
            tap("Search", x: 158, y: 862),
            tap("Profile", x: 354, y: 858),
        ]

        let result = ScrollAnchorDetector.computeOffset(
            previous: previous, current: current,
            windowHeight: windowHeight, minAnchors: 1
        )

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.anchorCount, 3)
        // All offsets are 0 (same position), so median is 0
        XCTAssertEqual(unwrapped.scrollOffset, 0.0, accuracy: 0.01)
    }

    func testComputeOffsetReturnsNilBelowMinAnchors() {
        let previous = [tap("Content A", y: 400)]
        let current = [tap("Content B", y: 400)]

        let result = ScrollAnchorDetector.computeOffset(
            previous: previous, current: current,
            windowHeight: windowHeight, minAnchors: 1
        )

        XCTAssertNil(result,
            "No anchor zone matches should return nil")
    }

    // MARK: - Median Offset

    func testMedianOffsetOddCount() {
        let matches = [
            ScrollAnchorDetector.AnchorMatch(text: "A", previousY: 860, currentY: 860),
            ScrollAnchorDetector.AnchorMatch(text: "B", previousY: 862, currentY: 860),
            ScrollAnchorDetector.AnchorMatch(text: "C", previousY: 858, currentY: 860),
        ]

        let median = ScrollAnchorDetector.medianOffset(from: matches)

        // Offsets: [0, 2, -2] → sorted: [-2, 0, 2] → median: 0
        XCTAssertEqual(median, 0.0, accuracy: 0.01)
    }

    func testMedianOffsetEvenCount() {
        let matches = [
            ScrollAnchorDetector.AnchorMatch(text: "A", previousY: 860, currentY: 860),
            ScrollAnchorDetector.AnchorMatch(text: "B", previousY: 862, currentY: 860),
        ]

        let median = ScrollAnchorDetector.medianOffset(from: matches)

        // Offsets: [0, 2] → sorted: [0, 2] → median: (0+2)/2 = 1
        XCTAssertEqual(median, 1.0, accuracy: 0.01)
    }
}
