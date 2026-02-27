// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ScrollDeduplicator: fuzzy dedup strategies and Levenshtein distance.
// ABOUTME: Covers exact, levenshtein, and proximity strategies with OCR-realistic test data.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ScrollDeduplicatorTests: XCTestCase {

    // MARK: - Helpers

    private func point(
        _ text: String, x: Double = 200, y: Double = 400, confidence: Float = 0.95
    ) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: confidence)
    }

    // MARK: - Levenshtein Distance

    func testLevenshteinDistanceIdenticalStrings() {
        XCTAssertEqual(ScrollDeduplicator.levenshteinDistance("hello", "hello"), 0)
    }

    func testLevenshteinDistanceSingleCharDiff() {
        XCTAssertEqual(ScrollDeduplicator.levenshteinDistance("cat", "bat"), 1)
    }

    func testLevenshteinDistanceOCRVariants() {
        // "O Activité" vs "D Activité" — single character substitution
        XCTAssertEqual(
            ScrollDeduplicator.levenshteinDistance("O Activité", "D Activité"), 1)
    }

    func testLevenshteinDistanceInsertion() {
        // "DActivité" vs "D Activité" — missing space = 1 insertion
        XCTAssertEqual(
            ScrollDeduplicator.levenshteinDistance("DActivité", "D Activité"), 1)
    }

    func testLevenshteinDistanceEmptyStrings() {
        XCTAssertEqual(ScrollDeduplicator.levenshteinDistance("", ""), 0)
        XCTAssertEqual(ScrollDeduplicator.levenshteinDistance("abc", ""), 3)
        XCTAssertEqual(ScrollDeduplicator.levenshteinDistance("", "xyz"), 3)
    }

    func testLevenshteinDistanceCompletelyDifferent() {
        XCTAssertEqual(ScrollDeduplicator.levenshteinDistance("abc", "xyz"), 3)
    }

    // MARK: - Exact Strategy

    func testExactStrategyKeepsDistinctTexts() {
        let elements = [
            point("O Activité", y: 100),
            point("D Activité", y: 200),
            point("DActivité", y: 300),
        ]

        let result = ScrollDeduplicator.deduplicate(
            elements, strategy: .exact)

        XCTAssertEqual(result.count, 3,
            "Exact strategy should not merge near-matches")
    }

    func testExactStrategyMergesIdenticalTexts() {
        let elements = [
            point("General", y: 100),
            point("Privacy", y: 200),
            point("General", y: 300),
        ]

        let result = ScrollDeduplicator.deduplicate(
            elements, strategy: .exact)

        XCTAssertEqual(result.count, 2)
        let texts = Set(result.map { $0.text })
        XCTAssertTrue(texts.contains("General"))
        XCTAssertTrue(texts.contains("Privacy"))
    }

    // MARK: - Levenshtein Strategy

    func testLevenshteinStrategyMergesOCRVariants() {
        let elements = [
            point("O Activité", y: 100, confidence: 0.80),
            point("D Activité", y: 200, confidence: 0.90),
            point("DActivité", y: 300, confidence: 0.85),
        ]

        let result = ScrollDeduplicator.deduplicate(
            elements, strategy: .levenshtein, levenshteinMax: 3)

        XCTAssertEqual(result.count, 1,
            "All OCR variants within edit distance 3 should merge into one")
    }

    func testLevenshteinStrategyKeepsHighestConfidence() {
        let elements = [
            point("O Activité", y: 100, confidence: 0.80),
            point("D Activité", y: 200, confidence: 0.95),
            point("DActivité", y: 300, confidence: 0.85),
        ]

        let result = ScrollDeduplicator.deduplicate(
            elements, strategy: .levenshtein, levenshteinMax: 3)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].confidence, 0.95,
            "Should keep the element with highest confidence")
    }

    func testLevenshteinStrategyKeepsDistantStrings() {
        let elements = [
            point("Activité", y: 100),
            point("Sommeil", y: 200),
            point("Respiration", y: 300),
        ]

        let result = ScrollDeduplicator.deduplicate(
            elements, strategy: .levenshtein, levenshteinMax: 3)

        XCTAssertEqual(result.count, 3,
            "Strings with distance > maxDistance should all survive")
    }

    func testLevenshteinStrategyRespectsThreshold() {
        let elements = [
            point("abc", y: 100, confidence: 0.90),
            point("xyz", y: 200, confidence: 0.85),
        ]

        // Distance "abc" -> "xyz" = 3; with max 2, should not merge
        let result2 = ScrollDeduplicator.deduplicate(
            elements, strategy: .levenshtein, levenshteinMax: 2)
        XCTAssertEqual(result2.count, 2)

        // With max 3, should merge
        let result3 = ScrollDeduplicator.deduplicate(
            elements, strategy: .levenshtein, levenshteinMax: 3)
        XCTAssertEqual(result3.count, 1)
    }

    // MARK: - Proximity Strategy

    func testProximityStrategyMergesNearbyElements() {
        let elements = [
            point("Activité", x: 100, y: 200, confidence: 0.80),
            point("b Activité", x: 105, y: 205, confidence: 0.90),
        ]

        // Distance = sqrt(25 + 25) ≈ 7.07, within 15pt threshold
        let result = ScrollDeduplicator.deduplicate(
            elements, strategy: .proximity, proximityPt: 15.0)

        XCTAssertEqual(result.count, 1,
            "Elements within 15pt should merge into one")
    }

    func testProximityStrategyKeepsDistantElements() {
        let elements = [
            point("Activité", x: 100, y: 200),
            point("Sommeil", x: 100, y: 400),
        ]

        // Distance = 200pt, well beyond threshold
        let result = ScrollDeduplicator.deduplicate(
            elements, strategy: .proximity, proximityPt: 15.0)

        XCTAssertEqual(result.count, 2,
            "Elements 200pt apart should both survive")
    }

    func testProximityStrategyKeepsHighestConfidence() {
        let elements = [
            point("Activité", x: 100, y: 200, confidence: 0.70),
            point("b Activité", x: 103, y: 203, confidence: 0.95),
            point("O Activité", x: 107, y: 197, confidence: 0.80),
        ]

        let result = ScrollDeduplicator.deduplicate(
            elements, strategy: .proximity, proximityPt: 15.0)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].confidence, 0.95,
            "Should keep the element with highest confidence")
    }

    func testProximityStrategyUsesEuclideanDistance() {
        // Two elements at exact threshold boundary
        // Distance = sqrt(10^2 + 10^2) ≈ 14.14 → within 15pt
        let near = [
            point("A", x: 0, y: 0, confidence: 0.90),
            point("B", x: 10, y: 10, confidence: 0.85),
        ]

        let nearResult = ScrollDeduplicator.deduplicate(
            near, strategy: .proximity, proximityPt: 15.0)
        XCTAssertEqual(nearResult.count, 1, "14.14pt < 15pt → should merge")

        // Distance = sqrt(11^2 + 11^2) ≈ 15.56 → beyond 15pt
        let far = [
            point("A", x: 0, y: 0, confidence: 0.90),
            point("B", x: 11, y: 11, confidence: 0.85),
        ]

        let farResult = ScrollDeduplicator.deduplicate(
            far, strategy: .proximity, proximityPt: 15.0)
        XCTAssertEqual(farResult.count, 2, "15.56pt > 15pt → should not merge")
    }

    // MARK: - Empty Input

    func testEmptyInputExact() {
        let result = ScrollDeduplicator.deduplicate([], strategy: .exact)
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyInputLevenshtein() {
        let result = ScrollDeduplicator.deduplicate(
            [], strategy: .levenshtein, levenshteinMax: 3)
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyInputProximity() {
        let result = ScrollDeduplicator.deduplicate(
            [], strategy: .proximity, proximityPt: 15.0)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Result Ordering

    func testResultsSortedByYCoordinate() {
        let elements = [
            point("C", x: 100, y: 500, confidence: 0.90),
            point("A", x: 100, y: 100, confidence: 0.90),
            point("B", x: 100, y: 300, confidence: 0.90),
        ]

        for strategy: ScrollDedupStrategy in [.exact, .levenshtein, .proximity] {
            let result = ScrollDeduplicator.deduplicate(
                elements, strategy: strategy, levenshteinMax: 0, proximityPt: 0)
            XCTAssertEqual(result.map { $0.text }, ["A", "B", "C"],
                "Results should be sorted by Y for strategy \(strategy)")
        }
    }
}
