// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for FrontierPlanner: global frontier scoring and cross-screen prioritization.
// ABOUTME: Verifies depth bonus, novelty bonus, tab root bonus, and best target selection.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class FrontierPlannerTests: XCTestCase {

    // MARK: - Test Helpers

    private let screenHeight: Double = 890

    private func tap(_ text: String, x: Double = 205, y: Double = 400) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    /// Create a NavigationGraph with multiple screens at different depths.
    /// Returns the graph and the backtrack stack (list of fingerprints from root to current).
    private func buildGraph(
        screens: [(elements: [TapPoint], screenType: ScreenType, visited: Set<String>)]
    ) -> (NavigationGraph, [String]) {
        let graph = NavigationGraph()

        guard !screens.isEmpty else { return (graph, []) }

        // Start with root screen
        let rootScreen = screens[0]
        graph.start(
            rootElements: rootScreen.elements,
            icons: [],
            hints: [],
            screenshot: "",
            screenType: rootScreen.screenType
        )

        let rootFP = graph.rootFingerprint
        // Mark visited elements on root
        for visited in rootScreen.visited {
            graph.markElementVisited(fingerprint: rootFP, elementText: visited)
        }

        var backtrackStack = [rootFP]

        // Add subsequent screens as transitions from the current screen
        for i in 1..<screens.count {
            let screen = screens[i]
            let result = graph.recordTransition(
                elements: screen.elements,
                icons: [],
                hints: [],
                screenshot: "",
                actionType: "tap",
                elementText: screen.elements.first?.text ?? "element-\(i)",
                screenType: screen.screenType
            )

            let fp: String?
            switch result {
            case .newScreen(let fingerprint):
                fp = fingerprint
            case .revisited(let fingerprint):
                fp = fingerprint
            case .duplicate:
                fp = nil
            }

            if let fp {
                // Mark visited elements
                for visited in screen.visited {
                    graph.markElementVisited(fingerprint: fp, elementText: visited)
                }
                backtrackStack.append(fp)
            }
        }

        return (graph, backtrackStack)
    }

    // MARK: - computeFrontierScore

    func testComputeFrontierScoreDepthBonus() {
        // Shallower screens should score higher due to depth bonus
        let shallowScore = FrontierPlanner.computeFrontierScore(
            elementScore: 3.0, screenDepth: 1, maxDepth: 5,
            visitedRatio: 0.5, isTabRoot: false
        )
        let deepScore = FrontierPlanner.computeFrontierScore(
            elementScore: 3.0, screenDepth: 4, maxDepth: 5,
            visitedRatio: 0.5, isTabRoot: false
        )

        // depth bonus = 2.0 * (maxDepth - depth)
        // shallow: 2.0 * (5-1) = 8.0, deep: 2.0 * (5-4) = 2.0
        XCTAssertGreaterThan(shallowScore, deepScore)
        XCTAssertEqual(shallowScore - deepScore, 6.0, accuracy: 0.01)
    }

    func testComputeFrontierScoreNoveltyBonus() {
        // Less-explored screens should score higher due to novelty bonus
        let freshScore = FrontierPlanner.computeFrontierScore(
            elementScore: 3.0, screenDepth: 2, maxDepth: 5,
            visitedRatio: 0.1, isTabRoot: false
        )
        let exploredScore = FrontierPlanner.computeFrontierScore(
            elementScore: 3.0, screenDepth: 2, maxDepth: 5,
            visitedRatio: 0.9, isTabRoot: false
        )

        // novelty = 1.5 * (1 - visitedRatio)
        // fresh: 1.5 * 0.9 = 1.35, explored: 1.5 * 0.1 = 0.15
        XCTAssertGreaterThan(freshScore, exploredScore)
        XCTAssertEqual(freshScore - exploredScore, 1.2, accuracy: 0.01)
    }

    func testComputeFrontierScoreTabRootBonus() {
        // Tab root screens should get a flat bonus
        let tabRootScore = FrontierPlanner.computeFrontierScore(
            elementScore: 3.0, screenDepth: 0, maxDepth: 3,
            visitedRatio: 0.5, isTabRoot: true
        )
        let regularScore = FrontierPlanner.computeFrontierScore(
            elementScore: 3.0, screenDepth: 0, maxDepth: 3,
            visitedRatio: 0.5, isTabRoot: false
        )

        XCTAssertEqual(tabRootScore - regularScore, FrontierPlanner.tabRootBonus, accuracy: 0.01)
    }

    // MARK: - bestTarget

    func testBestTargetReturnsShallowScreen() {
        // Build a 3-level deep graph:
        // root (depth 0, 1 unvisited) → mid (depth 1, 1 unvisited) → leaf (depth 2, current)
        let rootElements = [tap("Home", y: 400), tap("Settings", y: 500), tap("Profile", y: 600)]
        let midElements = [tap("General", y: 400), tap("Display", y: 500)]
        // Leaf has unique elements so it gets a different fingerprint
        let leafElements = [tap("Brightness", y: 400), tap("Theme", y: 500)]

        let (graph, stack) = buildGraph(screens: [
            (elements: rootElements, screenType: .settings, visited: ["Home", "Settings"]),
            (elements: midElements, screenType: .settings, visited: ["General"]),
            (elements: leafElements, screenType: .settings, visited: []),
        ])

        // Current screen is leaf (top of stack); ancestors are root and mid
        let target = FrontierPlanner.bestTarget(
            graph: graph, backtrackStack: stack, screenHeight: screenHeight
        )

        XCTAssertNotNil(target)
        // Root has "Profile" unvisited at depth 0; mid has "Display" unvisited at depth 1
        // Root should score higher due to depth bonus (2.0 * (2-0) = 4 vs 2.0 * (2-1) = 2)
        XCTAssertEqual(target?.fingerprint, stack[0], "Should prefer the shallower root screen")
        XCTAssertEqual(target?.element.text, "Profile")
    }

    func testBestTargetReturnsTabRoot() {
        // Tab root should be preferred even at same depth due to tabRootBonus
        let tabRootElements = [tap("Feed", y: 400), tap("Search", y: 800), tap("Profile", y: 800)]
        let regularElements = [tap("Details", y: 400), tap("More", y: 500)]
        let leafElements = [tap("Leaf Content", y: 400)]

        let (graph, stack) = buildGraph(screens: [
            (elements: tabRootElements, screenType: .tabRoot, visited: ["Feed"]),
            (elements: regularElements, screenType: .settings, visited: []),
            (elements: leafElements, screenType: .settings, visited: []),
        ])

        let target = FrontierPlanner.bestTarget(
            graph: graph, backtrackStack: stack, screenHeight: screenHeight
        )

        XCTAssertNotNil(target)
        // Tab root gets +5.0 bonus, should be preferred
        XCTAssertEqual(target?.fingerprint, stack[0], "Should prefer tab root screen")
    }

    func testBestTargetReturnsNilWhenAllVisited() {
        // All ancestor elements are visited → no frontier target
        let rootElements = [tap("Home", y: 400)]
        let midElements = [tap("General", y: 400)]
        let leafElements = [tap("Brightness", y: 400)]

        let (graph, stack) = buildGraph(screens: [
            (elements: rootElements, screenType: .settings, visited: ["Home"]),
            (elements: midElements, screenType: .settings, visited: ["General"]),
            (elements: leafElements, screenType: .settings, visited: []),
        ])

        let target = FrontierPlanner.bestTarget(
            graph: graph, backtrackStack: stack, screenHeight: screenHeight
        )

        XCTAssertNil(target, "Should return nil when all ancestors are fully visited")
    }

    func testBestTargetSkipsCurrentScreen() {
        // Current screen (top of stack) should NOT be considered as a frontier target
        let rootElements = [tap("Home", y: 400)]
        // Current screen has unvisited elements but should be skipped
        let currentElements = [tap("Button A", y: 400), tap("Button B", y: 500)]

        let (graph, stack) = buildGraph(screens: [
            (elements: rootElements, screenType: .settings, visited: ["Home"]),
            (elements: currentElements, screenType: .settings, visited: []),
        ])

        let target = FrontierPlanner.bestTarget(
            graph: graph, backtrackStack: stack, screenHeight: screenHeight
        )

        // Root is fully visited, current is skipped → nil
        XCTAssertNil(target, "Should skip the current screen at top of stack")
    }

    func testBestTargetSingleScreenReturnsNil() {
        // Only one screen (root = current) → no ancestors to check
        let rootElements = [tap("Home", y: 400), tap("Settings", y: 500)]

        let (graph, stack) = buildGraph(screens: [
            (elements: rootElements, screenType: .settings, visited: []),
        ])

        let target = FrontierPlanner.bestTarget(
            graph: graph, backtrackStack: stack, screenHeight: screenHeight
        )

        XCTAssertNil(target, "Should return nil when backtrack stack has only one screen")
    }

    func testBaseElementScorePrefersMidScreen() {
        // Elements in the middle content zone (10%-90%) should score 3.0,
        // elements in top/bottom edges should score 1.0
        let midScore = FrontierPlanner.computeFrontierScore(
            elementScore: 3.0, screenDepth: 0, maxDepth: 2,
            visitedRatio: 0.0, isTabRoot: false
        )
        let edgeScore = FrontierPlanner.computeFrontierScore(
            elementScore: 1.0, screenDepth: 0, maxDepth: 2,
            visitedRatio: 0.0, isTabRoot: false
        )

        // The only difference is elementScore: 3.0 vs 1.0
        XCTAssertEqual(midScore - edgeScore, 2.0, accuracy: 0.01)
    }
}
