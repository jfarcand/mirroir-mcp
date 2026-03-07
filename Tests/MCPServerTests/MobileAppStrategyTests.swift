// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for MobileAppStrategy: screen classification, element ranking, and backtracking.
// ABOUTME: Verifies tab bar detection, list/detail classification, skip patterns, and terminal detection.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class MobileAppStrategyTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        texts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 205, tapY: startY + Double(i) * 60, confidence: 0.95)
        }
    }

    private func makeTabBarElements() -> [TapPoint] {
        // Simulates a screen with a tab bar at the bottom
        let content = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 200, confidence: 0.95),
            TapPoint(text: "Privacy", tapX: 205, tapY: 280, confidence: 0.93),
        ]
        let tabBar = [
            TapPoint(text: "Home", tapX: 56, tapY: 850, confidence: 0.90),
            TapPoint(text: "Search", tapX: 158, tapY: 850, confidence: 0.90),
            TapPoint(text: "Profile", tapX: 260, tapY: 850, confidence: 0.90),
        ]
        return content + tabBar
    }

    // MARK: - Screen Classification

    func testClassifyTabRootScreen() {
        let elements = makeTabBarElements()

        let result = MobileAppStrategy.classifyScreen(elements: elements, hints: [])

        XCTAssertEqual(result, .tabRoot)
    }

    func testClassifyDetailScreen() {
        let elements = makeElements(["About", "Version 18.0"])
        let hints = ["Back navigation: \"<\" detected — tap it to go back."]

        let result = MobileAppStrategy.classifyScreen(elements: elements, hints: hints)

        XCTAssertEqual(result, .detail)
    }

    func testClassifyListScreen() {
        let elements = makeElements(["General", "Privacy", "About", "Display", "Sound"])
        let hints = ["Back navigation: \"<\" detected — tap it to go back."]

        let result = MobileAppStrategy.classifyScreen(elements: elements, hints: hints)

        XCTAssertEqual(result, .list)
    }

    func testClassifySettingsScreen() {
        let elements = makeElements(["General", "Privacy", "About", "Display", "Sound"])

        let result = MobileAppStrategy.classifyScreen(elements: elements, hints: [])

        XCTAssertEqual(result, .settings)
    }

    func testClassifyModalScreen() {
        let elements = [
            TapPoint(text: "Done", tapX: 350, tapY: 100, confidence: 0.95),
            TapPoint(text: "Select Language", tapX: 205, tapY: 200, confidence: 0.95),
            TapPoint(text: "English", tapX: 205, tapY: 300, confidence: 0.90),
        ]

        let result = MobileAppStrategy.classifyScreen(elements: elements, hints: [])

        XCTAssertEqual(result, .modal)
    }

    // MARK: - Element Ranking

    func testRankPrioritizesUnvisited() {
        let elements = makeElements(["General", "Privacy", "About", "Display"])
        let visited: Set<String> = ["General", "Privacy"]

        let ranked = MobileAppStrategy.rankElements(
            elements: elements, icons: [],
            visitedElements: visited, depth: 1, screenType: .settings
        )

        // Unvisited elements should come first
        let firstTwo = ranked.prefix(2).map(\.text)
        XCTAssertTrue(firstTwo.contains("About"))
        XCTAssertTrue(firstTwo.contains("Display"))
    }

    func testRankTabRootPrioritizesTabItems() {
        let tabBarElements = makeTabBarElements()
        let visited: Set<String> = []

        let ranked = MobileAppStrategy.rankElements(
            elements: tabBarElements, icons: [],
            visitedElements: visited, depth: 0, screenType: .tabRoot
        )

        // Tab bar items should be at the front
        XCTAssertFalse(ranked.isEmpty)
        // The first ranked elements should include tab bar items
        let topTexts = ranked.prefix(5).map(\.text)
        XCTAssertTrue(topTexts.contains("Home") || topTexts.contains("Search") || topTexts.contains("Profile"),
            "Tab bar items should be prioritized in .tabRoot")
    }

    func testRankSortsListByYPosition() {
        let elements = [
            TapPoint(text: "Zebra", tapX: 205, tapY: 300, confidence: 0.95),
            TapPoint(text: "Alpha", tapX: 205, tapY: 120, confidence: 0.95),
            TapPoint(text: "Middle", tapX: 205, tapY: 200, confidence: 0.95),
        ]

        let ranked = MobileAppStrategy.rankElements(
            elements: elements, icons: [],
            visitedElements: [], depth: 1, screenType: .list
        )

        let texts = ranked.map(\.text)
        XCTAssertEqual(texts, ["Alpha", "Middle", "Zebra"])
    }

    // MARK: - Backtracking

    func testBacktrackWithBackButton() {
        let hints = ["Back navigation: \"<\" detected — tap it to go back."]

        let result = MobileAppStrategy.backtrackMethod(currentHints: hints, depth: 2)

        XCTAssertEqual(result, .tapBack)
    }

    func testBacktrackWithoutBackButtonAtDepth() {
        let result = MobileAppStrategy.backtrackMethod(currentHints: [], depth: 2)

        XCTAssertEqual(result, .tapBack)
    }

    func testBacktrackAtRootDepth() {
        let result = MobileAppStrategy.backtrackMethod(currentHints: [], depth: 0)

        XCTAssertEqual(result, .none)
    }

    // MARK: - Skip Patterns

    func testShouldSkipDestructive() {
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            skipPatterns: ["Delete", "Sign Out", "Reset"]
        )
        XCTAssertTrue(MobileAppStrategy.shouldSkip(elementText: "Delete Account", budget: budget))
        XCTAssertTrue(MobileAppStrategy.shouldSkip(elementText: "Sign Out", budget: budget))
        XCTAssertTrue(MobileAppStrategy.shouldSkip(elementText: "Reset All Settings", budget: budget))
    }

    func testShouldNotSkipSafeElements() {
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0, skipPatterns: ["Delete", "Sign Out"]
        )
        XCTAssertFalse(MobileAppStrategy.shouldSkip(elementText: "General", budget: budget))
        XCTAssertFalse(MobileAppStrategy.shouldSkip(elementText: "About", budget: budget))
        XCTAssertFalse(MobileAppStrategy.shouldSkip(elementText: "Privacy", budget: budget))
    }

    // MARK: - Terminal Detection

    func testTerminalAtMaxDepth() {
        let budget = ExplorationBudget(
            maxDepth: 3, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 3, skipPatterns: []
        )
        let elements = makeElements(["Content"])

        XCTAssertTrue(MobileAppStrategy.isTerminal(
            elements: elements, depth: 3, budget: budget, screenType: .detail))
    }

    func testTerminalDetailWithNoChildren() {
        let budget = ExplorationBudget.default
        // Detail screen with only 1 navigable element
        let elements = [
            TapPoint(text: "Version 18.0", tapX: 205, tapY: 200, confidence: 0.95),
        ]

        XCTAssertTrue(MobileAppStrategy.isTerminal(
            elements: elements, depth: 2, budget: budget, screenType: .detail))
    }

    func testNotTerminalListWithChildren() {
        let budget = ExplorationBudget.default
        let elements = makeElements(["General", "Privacy", "About"])

        XCTAssertFalse(MobileAppStrategy.isTerminal(
            elements: elements, depth: 2, budget: budget, screenType: .list))
    }

    // MARK: - Fingerprint Delegation

    func testExtractFingerprintDelegatesToStructuralFingerprint() {
        let elements = makeElements(["Settings", "General"])
        let icons: [IconDetector.DetectedIcon] = []

        let fp1 = MobileAppStrategy.extractFingerprint(elements: elements, icons: icons)
        let fp2 = StructuralFingerprint.compute(elements: elements, icons: icons)

        XCTAssertEqual(fp1, fp2,
            "MobileAppStrategy should delegate fingerprinting to StructuralFingerprint")
    }

    // MARK: - Strategy-Based Guidance

    func testAnalyzeWithStrategyProducesSuggestions() {
        let graph = NavigationGraph()
        let elements = makeElements(["Settings", "General", "Privacy", "About"])
        graph.start(
            rootElements: elements, icons: [], hints: [],
            screenshot: "img", screenType: .settings
        )

        let guidance = ExplorationGuide.analyzeWithStrategy(
            strategy: MobileAppStrategy.self,
            graph: graph,
            elements: elements,
            icons: [],
            hints: [],
            budget: .default,
            goal: ""
        )

        XCTAssertFalse(guidance.suggestions.isEmpty,
            "Strategy-based analysis should produce suggestions")
    }

    func testAnalyzeWithStrategyDetectsGoalMatch() {
        let graph = NavigationGraph()
        let elements = makeElements(["Settings", "General", "Privacy", "About"])
        graph.start(
            rootElements: elements, icons: [], hints: [],
            screenshot: "img", screenType: .settings
        )

        let guidance = ExplorationGuide.analyzeWithStrategy(
            strategy: MobileAppStrategy.self,
            graph: graph,
            elements: elements,
            icons: [],
            hints: [],
            budget: .default,
            goal: "check privacy settings"
        )

        XCTAssertNotNil(guidance.goalProgress)
        XCTAssertTrue(guidance.goalProgress?.contains("Privacy") ?? false,
            "Should detect goal-relevant element 'Privacy'")
    }

    func testAnalyzeWithStrategySuggestsBacktrackWhenAllVisited() {
        let graph = NavigationGraph()
        let elements = makeElements(["Settings", "General"])
        graph.start(
            rootElements: elements, icons: [], hints: [],
            screenshot: "img", screenType: .settings
        )
        let fp = graph.currentFingerprint

        // Mark all elements as visited
        graph.markElementVisited(fingerprint: fp, elementText: "Settings")
        graph.markElementVisited(fingerprint: fp, elementText: "General")

        let guidance = ExplorationGuide.analyzeWithStrategy(
            strategy: MobileAppStrategy.self,
            graph: graph,
            elements: elements,
            icons: [],
            hints: [],
            budget: .default,
            goal: ""
        )

        let allSuggestions = guidance.suggestions.joined(separator: " ")
        XCTAssertTrue(allSuggestions.contains("All elements visited"),
            "Should suggest backtracking when all elements are visited")
    }
}
