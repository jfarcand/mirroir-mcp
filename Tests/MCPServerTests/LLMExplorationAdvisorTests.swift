// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for HeuristicExplorationAdvisor: element scoring and suggestion ranking.
// ABOUTME: VisionExplorationAdvisor tested separately via integration tests (requires embacle).

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class LLMExplorationAdvisorTests: XCTestCase {

    private let advisor = HeuristicExplorationAdvisor()

    private func tap(_ text: String, x: Double = 205, y: Double = 400) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    // MARK: - Heuristic Advisor

    func testEmptyElementsReturnsEmpty() {
        let result = advisor.suggest(
            screenshotBase64: "", elements: [],
            visitedElements: [], exploredScreenCount: 0
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testAllVisitedReturnsEmpty() {
        let elements = [tap("Settings"), tap("General")]
        let result = advisor.suggest(
            screenshotBase64: "", elements: elements,
            visitedElements: ["Settings", "General"], exploredScreenCount: 5
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testFiltersOutVisitedElements() {
        let elements = [tap("Settings"), tap("General"), tap("About")]
        let result = advisor.suggest(
            screenshotBase64: "", elements: elements,
            visitedElements: ["Settings"], exploredScreenCount: 2
        )
        let texts = result.map { $0.elementText }
        XCTAssertFalse(texts.contains("Settings"))
        XCTAssertTrue(texts.contains("General") || texts.contains("About"))
    }

    func testMaxThreeSuggestions() {
        let elements = (1...10).map { tap("Item \($0)", y: Double($0 * 50 + 200)) }
        let result = advisor.suggest(
            screenshotBase64: "", elements: elements,
            visitedElements: [], exploredScreenCount: 0
        )
        XCTAssertEqual(result.count, 3)
    }

    func testMidScreenElementsScoredHigher() {
        // Mid-screen element (y=400) should rank above edge elements (y=50, y=800)
        let elements = [
            tap("Edge Top", y: 50),
            tap("Mid", y: 400),
            tap("Edge Bottom", y: 800),
        ]
        let result = advisor.suggest(
            screenshotBase64: "", elements: elements,
            visitedElements: [], exploredScreenCount: 0
        )
        XCTAssertEqual(result.first?.elementText, "Mid",
            "Mid-screen element should be ranked first")
    }

    func testShortLabelsScoredHigher() {
        // Short label "OK" should score higher than a very long label
        let elements = [
            tap("This is a very long description label that spans many words", y: 400),
            tap("OK", y: 400),
        ]
        let result = advisor.suggest(
            screenshotBase64: "", elements: elements,
            visitedElements: [], exploredScreenCount: 0
        )
        XCTAssertEqual(result.first?.elementText, "OK",
            "Short labels should be ranked higher")
    }

    func testConfidenceIsPointFive() {
        let result = advisor.suggest(
            screenshotBase64: "", elements: [tap("Settings")],
            visitedElements: [], exploredScreenCount: 0
        )
        guard let first = result.first else { return XCTFail("Expected at least one suggestion") }
        XCTAssertEqual(first.confidence, 0.5, accuracy: 0.01)
    }

    func testReasoningIncludesYCoordinate() {
        let result = advisor.suggest(
            screenshotBase64: "", elements: [tap("Settings", y: 350)],
            visitedElements: [], exploredScreenCount: 0
        )
        XCTAssertTrue(result.first?.reasoning.contains("y=350") ?? false)
    }

    // MARK: - Vision Advisor Fallback

    func testVisionAdvisorFallsBackWithoutEmbacle() {
        // In test environment, EmbacleFFI.isAvailable is false,
        // so VisionExplorationAdvisor should fall back to heuristic
        let visionAdvisor = VisionExplorationAdvisor()
        let elements = [tap("Settings"), tap("General")]
        let result = visionAdvisor.suggest(
            screenshotBase64: "", elements: elements,
            visitedElements: [], exploredScreenCount: 0
        )
        // Should return heuristic results (non-empty)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.first?.confidence, 0.5,
            "Fallback to heuristic should have 0.5 confidence")
    }

    func testVisionAdvisorReturnsEmptyWhenAllVisited() {
        let visionAdvisor = VisionExplorationAdvisor()
        let elements = [tap("Settings")]
        let result = visionAdvisor.suggest(
            screenshotBase64: "", elements: elements,
            visitedElements: ["Settings"], exploredScreenCount: 0
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - ExplorationSuggestion

    func testExplorationSuggestionProperties() {
        let suggestion = ExplorationSuggestion(
            elementText: "Next", reasoning: "Test reason", confidence: 0.75
        )
        XCTAssertEqual(suggestion.elementText, "Next")
        XCTAssertEqual(suggestion.reasoning, "Test reason")
        XCTAssertEqual(suggestion.confidence, 0.75, accuracy: 0.01)
    }

    // MARK: - CoveragePhase

    func testCoveragePhaseRawValues() {
        XCTAssertEqual(CoveragePhase.discovery.rawValue, "discovery")
        XCTAssertEqual(CoveragePhase.plateau.rawValue, "plateau")
        XCTAssertEqual(CoveragePhase.exhaustion.rawValue, "exhaustion")
    }
}
