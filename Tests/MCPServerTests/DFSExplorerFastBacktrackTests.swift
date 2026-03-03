// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: DFSExplorer tests for tab bar fast-backtrack and depth limit behavior.
// ABOUTME: Covers fast backtrack triggers, shallow stack fallback, non-tab apps, and maxDepth.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class DFSExplorerFastBacktrackTests: XCTestCase {

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        makeExplorerElements(texts, startY: startY)
    }

    // MARK: - Tab Bar Fast-Backtrack

    func testFastBacktrackTriggersOnDeepTabApp() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Root is a tab bar screen with multiple tabs
        let rootElements: [TapPoint] = [
            TapPoint(text: "Home", tapX: 56, tapY: 850, confidence: 0.95),
            TapPoint(text: "Search", tapX: 158, tapY: 850, confidence: 0.95),
            TapPoint(text: "Profile", tapX: 260, tapY: 850, confidence: 0.95),
            TapPoint(text: "Featured", tapX: 205, tapY: 200, confidence: 0.95),
        ]
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        // Disable scouting — this test is about fast backtrack behavior
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            maxScoutsPerScreen: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Navigate deep: root -> level1 -> level2 -> level3
        let level1 = makeElements(["Section A", "Item 1"])
        let level2 = makeElements(["Detail X", "Info"])
        let level3 = makeElements(["Deep Data", "Value"])

        // Step 1: root -> level1
        let desc1 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: level1, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()
        _ = explorer.step(describer: desc1, input: input, strategy: MobileAppStrategy.self)

        // Step 2: level1 -> level2
        let desc2 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: level1, screenshotBase64: "img1"),
            ScreenDescriber.DescribeResult(elements: level2, screenshotBase64: "img2"),
        ])
        _ = explorer.step(describer: desc2, input: input, strategy: MobileAppStrategy.self)

        // Step 3: level2 -> level3
        let desc3 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: level2, screenshotBase64: "img2"),
            ScreenDescriber.DescribeResult(elements: level3, screenshotBase64: "img3"),
        ])
        _ = explorer.step(describer: desc3, input: input, strategy: MobileAppStrategy.self)

        // Mark all level3 elements as visited to trigger backtrack
        let graph = session.currentGraph
        let fp = graph.currentFingerprint
        for el in level3 { graph.markElementVisited(fingerprint: fp, elementText: el.text) }

        // Step 4: Should fast-backtrack to root (3 levels in one step)
        let desc4 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: level3, screenshotBase64: "img3"),
        ])

        let result = explorer.step(
            describer: desc4, input: input, strategy: MobileAppStrategy.self
        )

        if case .backtracked = result {
            // Should have tapped back button multiple times for fast backtrack
            let backTaps = input.taps.filter { $0.x < 60 && $0.y < 140 }
            XCTAssertEqual(backTaps.count, 3,
                "Fast backtrack from depth 3 should tap back 3 times")
        } else {
            XCTFail("Expected .backtracked for fast backtrack, got \(result)")
        }
    }

    func testFastBacktrackDoesNotTriggerForShallowStack() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Root is tabRoot
        let rootElements: [TapPoint] = [
            TapPoint(text: "Home", tapX: 56, tapY: 850, confidence: 0.95),
            TapPoint(text: "Search", tapX: 158, tapY: 850, confidence: 0.95),
            TapPoint(text: "Profile", tapX: 260, tapY: 850, confidence: 0.95),
            TapPoint(text: "Featured", tapX: 205, tapY: 200, confidence: 0.95),
        ]
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        // Disable scouting so tab root navigates directly (this test is about backtrack behavior)
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            maxScoutsPerScreen: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Navigate just one level deep (stackDepth=2, which is <= 2)
        let level1 = makeElements(["Detail Info", "Back"])
        let desc1 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: level1, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()
        _ = explorer.step(describer: desc1, input: input, strategy: MobileAppStrategy.self)

        // Mark all visited to trigger backtrack
        let graph = session.currentGraph
        let fp = graph.currentFingerprint
        for el in level1 { graph.markElementVisited(fingerprint: fp, elementText: el.text) }

        let desc2 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: level1, screenshotBase64: "img1"),
            // Backtrack verification: back at root
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
        ])

        let result = explorer.step(
            describer: desc2, input: input, strategy: MobileAppStrategy.self
        )

        if case .backtracked = result {
            // Normal single-step backtrack, not fast
            let backTaps = input.taps.filter { $0.x < 60 && $0.y < 140 }
            // Should be 1 (normal backtrack) not multiple (fast backtrack)
            XCTAssertEqual(backTaps.count, 1,
                "Shallow stack should use normal backtrack (1 tap)")
        } else {
            XCTFail("Expected .backtracked, got \(result)")
        }
    }

    func testFrontierBacktrackTriggersForDeepNonTabApp() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Root is settings (not tabRoot) — FrontierPlanner still triggers
        // because the root has unvisited elements and the depth bonus makes
        // it a higher-value target than the immediate parent.
        let rootElements = makeElements(["Settings", "General", "Privacy"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        // Disable scouting — this test is about backtrack behavior
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            maxScoutsPerScreen: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Navigate 3 levels deep
        let l1 = makeElements(["Section A", "Item 1"])
        let l2 = makeElements(["Detail X", "Info"])
        let l3 = makeElements(["Deep Val", "Data"])

        let desc1 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: l1, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()
        _ = explorer.step(describer: desc1, input: input, strategy: MobileAppStrategy.self)

        let desc2 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: l1, screenshotBase64: "img1"),
            ScreenDescriber.DescribeResult(elements: l2, screenshotBase64: "img2"),
        ])
        _ = explorer.step(describer: desc2, input: input, strategy: MobileAppStrategy.self)

        let desc3 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: l2, screenshotBase64: "img2"),
            ScreenDescriber.DescribeResult(elements: l3, screenshotBase64: "img3"),
        ])
        _ = explorer.step(describer: desc3, input: input, strategy: MobileAppStrategy.self)

        // Mark all l3 visited
        let graph = session.currentGraph
        let fp = graph.currentFingerprint
        for el in l3 { graph.markElementVisited(fingerprint: fp, elementText: el.text) }

        let tapsBefore = input.taps.count
        let desc4 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: l3, screenshotBase64: "img3"),
            // Frontier backtrack: 3 levels back through l2, l1, root
            ScreenDescriber.DescribeResult(elements: l2, screenshotBase64: "img2"),
            ScreenDescriber.DescribeResult(elements: l1, screenshotBase64: "img1"),
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
        ])

        let result = explorer.step(
            describer: desc4, input: input, strategy: MobileAppStrategy.self
        )

        if case .backtracked = result {
            // FrontierPlanner identifies root as the highest-value ancestor
            // even for non-tab apps, because depth bonus outweighs the tab bonus.
            let newBackTaps = input.taps.dropFirst(tapsBefore)
            let backButtonTaps = newBackTaps.filter { $0.x < 60 && $0.y < 140 }
            XCTAssertEqual(backButtonTaps.count, 3,
                "Deep non-tab app should frontier-backtrack to root (3 taps)")
        } else {
            XCTFail("Expected .backtracked for frontier backtrack, got \(result)")
        }
    }

    // MARK: - Depth Limit

    func testExplorerRespectsMaxDepth() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings", "General"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        // Budget with maxDepth=1 — can only go one level deep
        let budget = ExplorationBudget(
            maxDepth: 1, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 3,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Step 1: Tap to navigate one level deep
        let deepElements = makeElements(["About", "Version"])
        let describer1 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: deepElements, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()

        let step1 = explorer.step(
            describer: describer1, input: input, strategy: MobileAppStrategy.self
        )

        if case .continue = step1 {
            // Expected: navigated one level
        } else {
            XCTFail("Expected .continue for first step, got \(step1)")
        }

        // Step 2: At depth 1 with maxDepth=1, elements should be terminal
        // MobileAppStrategy.isTerminal checks depth >= budget.maxDepth
        let describer2 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: deepElements, screenshotBase64: "img1"),
            // Backtrack verification: back at root
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
        ])

        // Mark elements visited so it backtracks
        let graph = session.currentGraph
        let fp = graph.currentFingerprint
        for el in deepElements {
            graph.markElementVisited(fingerprint: fp, elementText: el.text)
        }

        let step2 = explorer.step(
            describer: describer2, input: input, strategy: MobileAppStrategy.self
        )

        // Should backtrack since all visited at depth limit
        if case .backtracked = step2 {
            // Expected
        } else if case .finished = step2 {
            // Also acceptable
        } else {
            XCTFail("Expected .backtracked or .finished at depth limit, got \(step2)")
        }
    }
}
