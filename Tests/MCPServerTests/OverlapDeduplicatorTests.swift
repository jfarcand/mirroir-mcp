// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for OverlapDeduplicator: viewport merging and overlap zone deduplication.
// ABOUTME: Verifies page-absolute Y projection, overlap detection, and edge cases.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class OverlapDeduplicatorTests: XCTestCase {

    private let windowHeight: Double = 890

    private func tap(_ text: String, x: Double = 205, y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    // MARK: - Absolute Y Projection

    func testToAbsoluteY() {
        XCTAssertEqual(
            OverlapDeduplicator.toAbsoluteY(100.0, cumulativeOffset: 0.0),
            100.0, accuracy: 0.01
        )
        XCTAssertEqual(
            OverlapDeduplicator.toAbsoluteY(100.0, cumulativeOffset: 500.0),
            600.0, accuracy: 0.01
        )
    }

    // MARK: - Merging

    func testMergeProjectsToAbsoluteY() {
        let accumulated: [TapPoint] = []
        let viewport = [
            tap("Item A", y: 100),
            tap("Item B", y: 200),
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: accumulated, newViewport: viewport,
            cumulativeOffset: 0, viewportOffset: 0,
            windowHeight: windowHeight, strategy: .exact
        )

        XCTAssertEqual(result.count, 2)
        // First viewport: pageY = tapY (offset is 0)
        XCTAssertEqual(result[0].tapY, 100, accuracy: 0.01)
        XCTAssertEqual(result[0].pageY, 100, accuracy: 0.01)
        XCTAssertEqual(result[1].tapY, 200, accuracy: 0.01)
        XCTAssertEqual(result[1].pageY, 200, accuracy: 0.01)
    }

    func testMergeDeduplicatesInOverlapZone() {
        let accumulated = [
            tap("Header", y: 100),
            tap("Item A", y: 300),
            tap("Item B", y: 500),
        ]
        let newViewport = [
            tap("Item B", y: 100),
            tap("Item C", y: 300),
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: accumulated, newViewport: newViewport,
            cumulativeOffset: 400, viewportOffset: 400,
            windowHeight: windowHeight, strategy: .exact
        )

        // "Item B" should be deduped (same text in accumulated)
        let texts = result.map(\.text)
        XCTAssertTrue(texts.contains("Header"))
        XCTAssertTrue(texts.contains("Item A"))
        XCTAssertTrue(texts.contains("Item B"))
        XCTAssertTrue(texts.contains("Item C"))
        // Count: 3 original + 1 new = 4
        XCTAssertEqual(texts.filter { $0 == "Item B" }.count, 1,
            "Item B should appear only once (deduped)")
    }

    func testMergeKeepsNonOverlappingElements() {
        let accumulated = [
            tap("Item A", y: 100),
        ]
        let newViewport = [
            tap("Item B", y: 300),
            tap("Item C", y: 500),
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: accumulated, newViewport: newViewport,
            cumulativeOffset: 200, viewportOffset: 200,
            windowHeight: windowHeight, strategy: .exact
        )

        XCTAssertEqual(result.count, 3)
        let texts = Set(result.map(\.text))
        XCTAssertTrue(texts.contains("Item A"))
        XCTAssertTrue(texts.contains("Item B"))
        XCTAssertTrue(texts.contains("Item C"))
    }

    func testEmptyNewViewport() {
        let accumulated = [
            tap("Item A", y: 100),
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: accumulated, newViewport: [],
            cumulativeOffset: 200, viewportOffset: 200,
            windowHeight: windowHeight, strategy: .exact
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "Item A")
    }

    func testEmptyAccumulated() {
        let newViewport = [
            tap("Item A", y: 100),
            tap("Item B", y: 200),
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: [], newViewport: newViewport,
            cumulativeOffset: 300, viewportOffset: 300,
            windowHeight: windowHeight, strategy: .exact
        )

        XCTAssertEqual(result.count, 2)
        // tapY stays viewport-relative, pageY is projected to absolute
        XCTAssertEqual(result[0].tapY, 100, accuracy: 0.01)
        XCTAssertEqual(result[0].pageY, 400, accuracy: 0.01)
        XCTAssertEqual(result[1].tapY, 200, accuracy: 0.01)
        XCTAssertEqual(result[1].pageY, 500, accuracy: 0.01)
    }

    func testMergeResultIsSortedByPageY() {
        let accumulated = [
            tap("Item C", y: 500),
            tap("Item A", y: 100),
        ]
        let newViewport = [
            tap("Item B", y: 200),
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: accumulated, newViewport: newViewport,
            cumulativeOffset: 100, viewportOffset: 100,
            windowHeight: windowHeight, strategy: .exact
        )

        // Verify sorted by pageY
        for i in 1..<result.count {
            XCTAssertLessThanOrEqual(result[i - 1].pageY, result[i].pageY,
                "Result should be sorted by page-absolute Y position")
        }
    }

    // MARK: - Composite Key Dedup

    func testCompositeKeyDifferentXKeepsBothIcons() {
        let key1 = OverlapDeduplicator.compositeKey(tap("icon", x: 50, y: 300), bucketSize: 20)
        let key2 = OverlapDeduplicator.compositeKey(tap("icon", x: 350, y: 300), bucketSize: 20)

        XCTAssertNotEqual(key1, key2,
            "Same text at different X buckets should produce different keys")
    }

    func testCompositeKeySameXBucketMatches() {
        let key1 = OverlapDeduplicator.compositeKey(tap("icon", x: 205, y: 300), bucketSize: 20)
        let key2 = OverlapDeduplicator.compositeKey(tap("icon", x: 210, y: 500), bucketSize: 20)

        XCTAssertEqual(key1, key2,
            "Same text in same X bucket should produce identical keys")
    }

    func testMergeSameTextDifferentXNotDeduped() {
        let accumulated = [
            TapPoint(text: "icon", tapX: 50, tapY: 300, confidence: 0.9, pageY: 300),
        ]
        let newViewport = [
            tap("icon", x: 350, y: 300),
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: accumulated, newViewport: newViewport,
            cumulativeOffset: 400, viewportOffset: 400,
            windowHeight: windowHeight, strategy: .exact
        )

        let iconCount = result.filter { $0.text == "icon" }.count
        XCTAssertEqual(iconCount, 2,
            "Icons at different X positions should both survive merge")
    }

    func testMergeSameTextSameXDeduped() {
        let accumulated = [
            TapPoint(text: "19:34", tapX: 336, tapY: 579, confidence: 0.9, pageY: 579),
        ]
        let newViewport = [
            tap("19:34", x: 336, y: 179),  // Same text, same X, after scroll
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: accumulated, newViewport: newViewport,
            cumulativeOffset: 400, viewportOffset: 400,
            windowHeight: windowHeight, strategy: .exact
        )

        let count = result.filter { $0.text == "19:34" }.count
        XCTAssertEqual(count, 1,
            "Same text at same X across viewports should be deduped")
    }

    // MARK: - Page-Absolute Y

    func testMergePreservesViewportTapY() {
        let newViewport = [
            tap("Item A", y: 200),
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: [], newViewport: newViewport,
            cumulativeOffset: 500, viewportOffset: 500,
            windowHeight: windowHeight, strategy: .exact
        )

        // tapY should stay viewport-relative
        XCTAssertEqual(result[0].tapY, 200, accuracy: 0.01)
        // pageY should be absolute
        XCTAssertEqual(result[0].pageY, 700, accuracy: 0.01)
    }

    // MARK: - Substring Containment Dedup

    func testSubstringFragmentSuppressedByLongerElement() {
        // "marche" is a substring of "• Distance (marche et course)"
        // and should be suppressed when nearby in page-absolute Y.
        let accumulated = [
            TapPoint(text: "• Distance (marche et course)", tapX: 158, tapY: 565, confidence: 0.9, pageY: 565),
        ]
        let newViewport = [
            tap("marche", x: 158, y: 165),  // Same X, after scroll offset
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: accumulated, newViewport: newViewport,
            cumulativeOffset: 400, viewportOffset: 400,
            windowHeight: windowHeight, strategy: .exact
        )

        XCTAssertEqual(result.count, 1,
            "Substring fragment 'marche' should be suppressed by longer element")
        XCTAssertEqual(result[0].text, "• Distance (marche et course)")
    }

    func testShortSubstringNotSuppressed() {
        // "On" (2 chars) is too short for substring suppression — could match "Notifications"
        let accumulated = [
            TapPoint(text: "Notifications", tapX: 100, tapY: 300, confidence: 0.9, pageY: 300),
        ]
        let newViewport = [
            tap("On", x: 350, y: 300),
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: accumulated, newViewport: newViewport,
            cumulativeOffset: 0, viewportOffset: 0,
            windowHeight: windowHeight, strategy: .exact
        )

        XCTAssertEqual(result.count, 2,
            "Short text (< 5 chars) should not be suppressed by substring matching")
    }

    func testSubstringNotSuppressedWhenFarAway() {
        // Same text substring but at very different Y positions — not a duplicate
        let accumulated = [
            TapPoint(text: "• Distance (marche et course)", tapX: 158, tapY: 100, confidence: 0.9, pageY: 100),
        ]
        let newViewport = [
            tap("marche", x: 158, y: 200),  // pageY = 200 + 800 = 1000, far from 100
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: accumulated, newViewport: newViewport,
            cumulativeOffset: 800, viewportOffset: 800,
            windowHeight: windowHeight, strategy: .exact
        )

        XCTAssertEqual(result.count, 2,
            "Substring at distant Y should not be suppressed")
    }

    func testMergePageYUsedForSorting() {
        let accumulated = [
            TapPoint(text: "Header", tapX: 100, tapY: 100, confidence: 0.9, pageY: 100),
        ]
        let newViewport = [
            tap("Footer", x: 100, y: 50),  // low viewport Y but high page Y
        ]

        let result = OverlapDeduplicator.merge(
            accumulated: accumulated, newViewport: newViewport,
            cumulativeOffset: 800, viewportOffset: 800,
            windowHeight: windowHeight, strategy: .exact
        )

        // Header pageY=100, Footer pageY=50+800=850
        XCTAssertEqual(result[0].text, "Header")
        XCTAssertEqual(result[1].text, "Footer")
    }
}
