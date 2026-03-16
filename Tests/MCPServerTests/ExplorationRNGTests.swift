// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ExplorationRNG: deterministic seeded PRNG and canonical ordering.
// ABOUTME: Verifies reproducibility guarantees for deterministic exploration mode.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ExplorationRNGTests: XCTestCase {

    private func tap(_ text: String, x: Double = 205, y: Double = 400) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    // MARK: - Seeded Determinism

    func testSameSeedProducesSameSequence() {
        let rng1 = ExplorationRNG(seed: 42)
        let rng2 = ExplorationRNG(seed: 42)

        let seq1 = (0..<10).map { _ in rng1.nextUInt64() }
        let seq2 = (0..<10).map { _ in rng2.nextUInt64() }
        XCTAssertEqual(seq1, seq2)
    }

    func testDifferentSeedsProduceDifferentSequences() {
        let rng1 = ExplorationRNG(seed: 42)
        let rng2 = ExplorationRNG(seed: 99)

        let val1 = rng1.nextUInt64()
        let val2 = rng2.nextUInt64()
        XCTAssertNotEqual(val1, val2)
    }

    func testIsSeededFlagTrue() {
        let rng = ExplorationRNG(seed: 1)
        XCTAssertTrue(rng.isSeeded)
    }

    func testIsSeededFlagFalseForSystemRandom() {
        let rng = ExplorationRNG()
        XCTAssertFalse(rng.isSeeded)
    }

    // MARK: - Next Double

    func testNextDoubleInRange() {
        let rng = ExplorationRNG(seed: 42)
        for _ in 0..<100 {
            let val = rng.nextDouble()
            XCTAssertGreaterThanOrEqual(val, 0.0)
            XCTAssertLessThan(val, 1.0)
        }
    }

    // MARK: - Shuffle

    func testShuffleDeterministic() {
        let rng1 = ExplorationRNG(seed: 42)
        let rng2 = ExplorationRNG(seed: 42)
        var arr1 = [1, 2, 3, 4, 5, 6, 7, 8]
        var arr2 = [1, 2, 3, 4, 5, 6, 7, 8]
        rng1.shuffle(&arr1)
        rng2.shuffle(&arr2)
        XCTAssertEqual(arr1, arr2)
    }

    func testShuffleActuallyPermutes() {
        let rng = ExplorationRNG(seed: 42)
        var arr = Array(0..<20)
        let original = arr
        rng.shuffle(&arr)
        // Very unlikely to be identical after shuffling 20 elements
        XCTAssertNotEqual(arr, original)
    }

    // MARK: - Tiebreaker

    func testTiebreakerDeterministic() {
        let rng1 = ExplorationRNG(seed: 42)
        let rng2 = ExplorationRNG(seed: 42)
        let tb1 = rng1.tiebreaker(for: "Settings")
        let tb2 = rng2.tiebreaker(for: "Settings")
        XCTAssertEqual(tb1, tb2, accuracy: 1e-10)
    }

    func testTiebreakerSmallMagnitude() {
        let rng = ExplorationRNG(seed: 42)
        let tb = rng.tiebreaker(for: "Settings")
        XCTAssertLessThan(abs(tb), 0.01,
            "Tiebreaker should be a small value")
    }

    // MARK: - Canonical Ordering

    func testCanonicalOrderByY() {
        let elements = [
            tap("Bottom", y: 400),
            tap("Top", y: 100),
            tap("Middle", y: 250),
        ]
        let ordered = ExplorationRNG.canonicalOrder(elements)
        XCTAssertEqual(ordered.map { $0.text }, ["Top", "Middle", "Bottom"])
    }

    func testCanonicalOrderByXWhenYSimilar() {
        let elements = [
            tap("Right", x: 300, y: 200),
            tap("Left", x: 50, y: 205),
            tap("Center", x: 175, y: 198),
        ]
        // All within 10pt Y tolerance → sorted by X
        let ordered = ExplorationRNG.canonicalOrder(elements)
        XCTAssertEqual(ordered.map { $0.text }, ["Left", "Center", "Right"])
    }

    func testCanonicalOrderStable() {
        let elements = [
            tap("B", x: 100, y: 200),
            tap("A", x: 200, y: 200),
            tap("C", x: 50, y: 500),
        ]
        let order1 = ExplorationRNG.canonicalOrder(elements)
        let order2 = ExplorationRNG.canonicalOrder(elements)
        XCTAssertEqual(order1.map { $0.text }, order2.map { $0.text })
    }

    func testCanonicalOrderEmpty() {
        let ordered = ExplorationRNG.canonicalOrder([])
        XCTAssertTrue(ordered.isEmpty)
    }

    // MARK: - OCR Stabilization

    func testStabilizedDescribeWithStableOCR() {
        let describer = StubDescriber()
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [tap("Settings"), tap("General")], screenshotBase64: ""
        )
        let result = ExplorerUtilities.stabilizedDescribe(describer: describer)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.elements.count, 2)
    }

    func testStabilizedDescribeReturnsNilOnFailure() {
        let describer = StubDescriber()
        describer.describeResult = nil
        let result = ExplorerUtilities.stabilizedDescribe(describer: describer)
        XCTAssertNil(result)
    }
}
