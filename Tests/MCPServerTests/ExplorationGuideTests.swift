// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ExplorationGuide: suggestion engine for AI-driven app exploration.
// ABOUTME: Covers goal-driven, discovery mode, keyword extraction, element ranking, and formatting.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ExplorationGuideTests: XCTestCase {

    // MARK: - Keyword Extraction

    func testExtractKeywordsFiltersStopWords() {
        let keywords = ExplorationGuide.extractKeywords(from: "check the software version")
        XCTAssertTrue(keywords.contains("software"))
        XCTAssertTrue(keywords.contains("version"))
        XCTAssertFalse(keywords.contains("the"), "Stop word 'the' should be filtered")
        XCTAssertFalse(keywords.contains("check"), "Stop word 'check' should be filtered")
    }

    func testExtractKeywordsHandlesEmptyGoal() {
        let keywords = ExplorationGuide.extractKeywords(from: "")
        XCTAssertTrue(keywords.isEmpty)
    }

    func testExtractKeywordsFiltersSingleCharWords() {
        let keywords = ExplorationGuide.extractKeywords(from: "a b version")
        XCTAssertEqual(keywords, ["version"])
    }

    // MARK: - Element Filtering

    func testFilterNavigableElementsExcludesStatusBar() {
        let elements = [
            TapPoint(text: "9:41", tapX: 175, tapY: 30, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
        ]
        let filtered = ExplorationGuide.filterNavigableElements(elements)
        let texts = filtered.map(\.text)
        XCTAssertFalse(texts.contains("9:41"), "Status bar time should be filtered")
        XCTAssertTrue(texts.contains("Settings"))
        XCTAssertTrue(texts.contains("General"))
    }

    func testFilterNavigableElementsExcludesShortText() {
        let elements = [
            TapPoint(text: "OK", tapX: 205, tapY: 300, confidence: 0.95),
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
        ]
        let filtered = ExplorationGuide.filterNavigableElements(elements)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.text, "General")
    }

    func testFilterNavigableElementsSortsByY() {
        let elements = [
            TapPoint(text: "About", tapX: 205, tapY: 400, confidence: 0.95),
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
        ]
        let filtered = ExplorationGuide.filterNavigableElements(elements)
        XCTAssertEqual(filtered.map(\.text), ["Settings", "General", "About"])
    }

    // MARK: - Goal Relevance Ranking

    func testRankByGoalRelevancePrioritizesMatches() {
        let candidates = [
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
            TapPoint(text: "Software Update", tapX: 205, tapY: 490, confidence: 0.92),
            TapPoint(text: "Privacy", tapX: 205, tapY: 370, confidence: 0.93),
        ]
        let keywords = ["software", "version"]
        let ranked = ExplorationGuide.rankByGoalRelevance(candidates: candidates, keywords: keywords)
        XCTAssertEqual(ranked.first?.text, "Software Update",
            "Element containing goal keyword should rank first")
    }

    func testRankByGoalRelevancePreservesOrderWithNoKeywords() {
        let candidates = [
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
            TapPoint(text: "About", tapX: 205, tapY: 400, confidence: 0.92),
        ]
        let ranked = ExplorationGuide.rankByGoalRelevance(candidates: candidates, keywords: [])
        XCTAssertEqual(ranked.map(\.text), ["General", "About"],
            "Without keywords, order should be preserved")
    }

    // MARK: - Goal-Driven Analysis

    func testGoalDrivenDetectsGoalContent() {
        let elements = [
            TapPoint(text: "About", tapX: 205, tapY: 120, confidence: 0.96),
            TapPoint(text: "iOS Version 18.2", tapX: 205, tapY: 300, confidence: 0.88),
            TapPoint(text: "Model Name", tapX: 205, tapY: 360, confidence: 0.90),
        ]
        let guidance = ExplorationGuide.analyze(
            mode: .goalDriven,
            goal: "check software version",
            elements: elements,
            hints: [],
            startElements: nil,
            actionLog: [],
            screenCount: 3
        )
        XCTAssertNotNil(guidance.goalProgress)
        XCTAssertTrue(guidance.goalProgress?.contains("Goal-relevant content visible") ?? false,
            "Should detect 'version' keyword in 'iOS Version 18.2'")
        XCTAssertTrue(guidance.suggestions.contains(where: { $0.contains("Remember") }),
            "Should suggest Remember when goal content is visible")
    }

    func testGoalDrivenDetectsPartialKeywordMatch() {
        // "Software Update" matches "software" keyword — guide should detect it as goal-relevant
        let elements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
            TapPoint(text: "Software Update", tapX: 205, tapY: 490, confidence: 0.92),
            TapPoint(text: "Privacy", tapX: 205, tapY: 370, confidence: 0.93),
        ]
        let guidance = ExplorationGuide.analyze(
            mode: .goalDriven,
            goal: "check software version",
            elements: elements,
            hints: [],
            startElements: nil,
            actionLog: [],
            screenCount: 1
        )
        XCTAssertTrue(guidance.goalProgress?.contains("Goal-relevant content visible") ?? false,
            "Should detect 'software' keyword match in 'Software Update'")
        XCTAssertTrue(guidance.suggestions.contains(where: { $0.contains("Remember") }),
            "Should suggest Remember when keyword-matching content is visible")
    }

    func testGoalDrivenSuggestsNavigationWhenGoalNotVisible() {
        // Elements that do NOT match any keyword from the goal
        let elements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
            TapPoint(text: "Privacy", tapX: 205, tapY: 370, confidence: 0.93),
            TapPoint(text: "Display", tapX: 205, tapY: 430, confidence: 0.92),
        ]
        let guidance = ExplorationGuide.analyze(
            mode: .goalDriven,
            goal: "check software version",
            elements: elements,
            hints: [],
            startElements: nil,
            actionLog: [],
            screenCount: 1
        )
        XCTAssertTrue(guidance.goalProgress?.contains("not yet visible") ?? false)
        XCTAssertFalse(guidance.suggestions.isEmpty, "Should provide navigation suggestions")
        XCTAssertTrue(
            guidance.suggestions.first?.contains("Tap") ?? false,
            "Should suggest tapping elements when goal not visible. Got: \(guidance.suggestions)")
    }

    // MARK: - Discovery Analysis

    func testDiscoveryFirstScreenListsFlows() {
        let elements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
            TapPoint(text: "Privacy", tapX: 205, tapY: 370, confidence: 0.93),
            TapPoint(text: "About", tapX: 205, tapY: 430, confidence: 0.92),
        ]
        let guidance = ExplorationGuide.analyze(
            mode: .discovery,
            goal: "",
            elements: elements,
            hints: [],
            startElements: nil,
            actionLog: [],
            screenCount: 1
        )
        XCTAssertTrue(guidance.goalProgress?.contains("Discovery mode") ?? false)
        XCTAssertTrue(guidance.suggestions.contains(where: { $0.contains("explore this flow") }),
            "Discovery mode should suggest flows to explore")
    }

    func testDiscoveryBackAtStartSuggestsNextFlow() {
        let startElements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
        ]
        let guidance = ExplorationGuide.analyze(
            mode: .discovery,
            goal: "",
            elements: startElements,
            hints: [],
            startElements: startElements,
            actionLog: [],
            screenCount: 3
        )
        XCTAssertTrue(guidance.isFlowComplete, "Should detect flow completion")
        XCTAssertTrue(guidance.goalProgress?.contains("Back at start") ?? false)
    }

    func testDiscoveryMidExplorationSuggestsBack() {
        let elements = [
            TapPoint(text: "About", tapX: 205, tapY: 120, confidence: 0.96),
            TapPoint(text: "iOS Version", tapX: 205, tapY: 300, confidence: 0.88),
        ]
        let startElements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
        ]
        let guidance = ExplorationGuide.analyze(
            mode: .discovery,
            goal: "",
            elements: elements,
            hints: [],
            startElements: startElements,
            actionLog: [],
            screenCount: 3
        )
        XCTAssertFalse(guidance.isFlowComplete)
        XCTAssertTrue(guidance.suggestions.contains(where: { $0.contains("Tap the back button") }),
            "Mid-exploration on mobile should suggest tapping back button")
    }

    func testDiscoveryMidExplorationSuggestsBackDesktop() {
        let elements = [
            TapPoint(text: "About", tapX: 205, tapY: 120, confidence: 0.96),
            TapPoint(text: "iOS Version", tapX: 205, tapY: 300, confidence: 0.88),
        ]
        let startElements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
        ]
        let guidance = ExplorationGuide.analyze(
            mode: .discovery,
            goal: "",
            elements: elements,
            hints: [],
            startElements: startElements,
            actionLog: [],
            screenCount: 3,
            isMobile: false
        )
        XCTAssertFalse(guidance.isFlowComplete)
        XCTAssertTrue(guidance.suggestions.contains(where: { $0.contains("Press Back") }),
            "Mid-exploration on desktop should suggest Press Back (Cmd+[)")
    }

    // MARK: - Stuck Detection

    func testStuckWarningAfterConsecutiveDuplicates() {
        let actionLog: [ExplorationAction] = (0..<3).map { _ in
            ExplorationAction(actionType: "tap", arrivedVia: "Button", wasDuplicate: true)
        }
        let elements = [
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
        ]
        let guidance = ExplorationGuide.analyze(
            mode: .goalDriven,
            goal: "test",
            elements: elements,
            hints: [],
            startElements: nil,
            actionLog: actionLog,
            screenCount: 2
        )
        XCTAssertNotNil(guidance.warning, "Should produce a stuck warning")
        XCTAssertTrue(guidance.warning?.contains("stuck") ?? false)
    }

    func testNoWarningBelowStuckThreshold() {
        let actionLog: [ExplorationAction] = [
            ExplorationAction(actionType: "tap", arrivedVia: "A", wasDuplicate: true),
        ]
        let elements = [
            TapPoint(text: "General", tapX: 205, tapY: 250, confidence: 0.95),
        ]
        let guidance = ExplorationGuide.analyze(
            mode: .goalDriven,
            goal: "test",
            elements: elements,
            hints: [],
            startElements: nil,
            actionLog: actionLog,
            screenCount: 2
        )
        XCTAssertNil(guidance.warning, "Should not warn below stuck threshold")
    }

    // MARK: - Guidance Formatting

    func testFormatGuidanceWithGoalProgress() {
        let guidance = ExplorationGuide.Guidance(
            suggestions: ["Tap \"About\"", "Scroll down"],
            goalProgress: "Goal \"check version\" — not yet visible.",
            warning: nil,
            isFlowComplete: false
        )
        let text = ExplorationGuide.formatGuidance(guidance)
        XCTAssertTrue(text.contains("Exploration guidance:"))
        XCTAssertTrue(text.contains("Tap \"About\""))
        XCTAssertTrue(text.contains("Scroll down"))
    }

    func testFormatGuidanceWithFlowComplete() {
        let guidance = ExplorationGuide.Guidance(
            suggestions: [],
            goalProgress: nil,
            warning: nil,
            isFlowComplete: true
        )
        let text = ExplorationGuide.formatGuidance(guidance)
        XCTAssertTrue(text.contains("Flow appears complete"))
        XCTAssertTrue(text.contains("action=\"finish\""))
    }

    func testFormatGuidanceWithWarning() {
        let guidance = ExplorationGuide.Guidance(
            suggestions: [],
            goalProgress: nil,
            warning: "Agent appears stuck",
            isFlowComplete: false
        )
        let text = ExplorationGuide.formatGuidance(guidance)
        XCTAssertTrue(text.contains("Warning:"))
        XCTAssertTrue(text.contains("stuck"))
    }
}
