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
        // First viewport: absolute Y = viewport Y (offset is 0)
        XCTAssertEqual(result[0].tapY, 100, accuracy: 0.01)
        XCTAssertEqual(result[1].tapY, 200, accuracy: 0.01)
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
        // Should project to absolute Y
        XCTAssertEqual(result[0].tapY, 400, accuracy: 0.01)
        XCTAssertEqual(result[1].tapY, 500, accuracy: 0.01)
    }

    func testMergeResultIsSortedByY() {
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

        // Verify sorted by Y
        for i in 1..<result.count {
            XCTAssertLessThanOrEqual(result[i - 1].tapY, result[i].tapY,
                "Result should be sorted by Y position")
        }
    }
}
