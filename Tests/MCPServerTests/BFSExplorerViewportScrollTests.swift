// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for BFS multi-viewport exploration and per-viewport scrolling.
// ABOUTME: Verifies scroll-exhaustion bypass and the calibration scroll cap taken from the recipe.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

extension BFSExplorerScrollTests {

    // MARK: - BFS: Multi-Viewport Exploration

    // MARK: - BFS: Per-Viewport Scrolling Bypasses Scroll Exhaustion

    /// When skipCalibration is true, performScrollIfAvailable should scroll even
    /// after CalibrationScroller marked the page as scroll-exhausted. This is the
    /// core fix that enables per-viewport exploration.
    func testSkipCalibrationBypassesScrollExhaustion() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings", "General"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 2, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 1, scrollLimit: 2,
            calibrationScrollLimit: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        // WITH skipCalibration: scroll should work despite exhaustion
        let explorer = BFSExplorer(
            session: session, budget: budget, skipCalibration: true
        )
        explorer.markStarted()

        // Manually mark scroll as exhausted (simulates CalibrationScroller)
        let graph = session.currentGraph
        graph.markScrollExhausted(fingerprint: graph.rootFingerprint)

        let rootScreen = makeScreen(["Settings", "General"])
        let scrolledScreen = makeScreen(["Settings", "General", "About"])

        // Step 1: tap Settings → duplicate. Step 2: action limit → scroll → "About" is novel
        let screens: [ScreenDescriber.DescribeResult] = [
            rootScreen, rootScreen,     // step 1: viewport + after-tap
            rootScreen, scrolledScreen,  // step 2: viewport + scroll result
        ]
        let describer = MockExplorerDescriber(screens: screens)
        let input = MockExplorerInput()

        var scrollHappened = false
        for _ in 0..<4 {
            let result = explorer.step(
                describer: describer, input: input, strategy: MobileAppStrategy.self
            )
            if case .continue(let d) = result, d.contains("Scrolled") {
                scrollHappened = true
                break
            }
        }

        XCTAssertTrue(scrollHappened,
            "skipCalibration=true should allow scrolling even when scroll exhausted")
        XCTAssertGreaterThanOrEqual(input.swipes.filter({ $0.fromY > $0.toY }).count, 1,
            "Should have performed at least one scroll-down swipe")
    }

    // MARK: - Calibration Scroll Cap From Recipe

    /// A matched recipe declaring calibrationScrollLimit=2 must cap calibration
    /// scrolling at 2 forward swipes even when every scroll reveals novel
    /// elements (infinite feed) and the budget default (15) would allow more.
    func testCalibrationScrollCappedByRecipeLimit() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")
        session.capture(
            elements: makeElements(["Post1"]), hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let recipe = ScreenRecipe(
            name: "feed", platform: "ios", description: "Feed",
            requiredComponents: ["feed-post"],
            supportingComponents: [], forbiddenComponents: [],
            navigationModel: RecipeNavigationModel(
                type: "infinite-scroll", backtrack: "tap-tab",
                scrollBehavior: "infinite", depthPattern: "flat",
                calibrationScrollLimit: 2),
            explorationHints: [])
        session.setRecipeMatch(RecipeMatch(recipe: recipe, score: 10, reason: "test"))

        let budget = ExplorationBudget(
            maxDepth: 2, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 1,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )
        // No bridge → scrollAndCollect uses the simple scroll loop.
        let explorer = BFSExplorer(session: session, budget: budget)
        XCTAssertEqual(explorer.effectiveCalibrationScrollLimit, 2,
            "Recipe cap should override the budget default (15)")

        // Every scroll reveals a new post — only the cap can stop the loop.
        var texts = ["Post1"]
        let screens: [ScreenDescriber.DescribeResult] = (2...20).map { i in
            texts.append("Post\(i)")
            return makeScreen(texts)
        }
        let describer = MockExplorerDescriber(screens: screens)
        let input = MockExplorerInput()

        let graph = session.currentGraph
        let data = explorer.scrollAndCollect(
            fingerprint: graph.rootFingerprint, describer: describer, input: input
        )

        XCTAssertEqual(data.scrollCount, 2, "Recipe cap should stop calibration at 2 scrolls")
        // Forward calibration swipes go top-to-bottom on screen (fromY > toY);
        // scroll-back swipes are the reverse.
        let forwardSwipes = input.swipes.filter { $0.fromY > $0.toY }
        XCTAssertEqual(forwardSwipes.count, 2,
            "Should perform exactly 2 forward calibration swipes")
    }

    /// Same recipe cap, but through the bridge path: with a bridge present,
    /// scrollAndCollect delegates to describeFullPage/CalibrationScroller and
    /// must pass the effective (recipe-capped) limit as maxScrolls.
    func testCalibrationScrollCapReachesCalibrationScroller() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")
        session.capture(
            elements: makeElements(["Post1"]), hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let recipe = ScreenRecipe(
            name: "feed", platform: "ios", description: "Feed",
            requiredComponents: ["feed-post"],
            supportingComponents: [], forbiddenComponents: [],
            navigationModel: RecipeNavigationModel(
                type: "infinite-scroll", backtrack: "tap-tab",
                scrollBehavior: "infinite", depthPattern: "flat",
                calibrationScrollLimit: 2),
            explorationHints: [])
        session.setRecipeMatch(RecipeMatch(recipe: recipe, score: 10, reason: "test"))

        let budget = ExplorationBudget(
            maxDepth: 2, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 1,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )
        let explorer = BFSExplorer(
            session: session, budget: budget, bridge: StubWindowBridge()
        )

        // Every scroll reveals a new post — only the cap can stop the scroller.
        var texts = ["Post1"]
        var screens: [ScreenDescriber.DescribeResult] = [makeScreen(texts)]
        for i in 2...20 {
            texts.append("Post\(i)")
            screens.append(makeScreen(texts))
        }
        let describer = MockExplorerDescriber(screens: screens)
        let input = MockExplorerInput()

        let graph = session.currentGraph
        let data = explorer.scrollAndCollect(
            fingerprint: graph.rootFingerprint, describer: describer, input: input
        )

        XCTAssertTrue(data.usedCalibrationScroller,
            "A bridge must route calibration through CalibrationScroller")
        XCTAssertEqual(data.scrollCount, 2,
            "CalibrationScroller must receive the recipe-capped maxScrolls")
        let forwardSwipes = input.swipes.filter { $0.fromY > $0.toY }
        XCTAssertEqual(forwardSwipes.count, 2,
            "Should perform exactly 2 forward calibration swipes via the bridge path")
    }

    /// Without skipCalibration, scroll-exhausted screens should NOT scroll further.
    func testScrollExhaustedBlocksWithoutSkipCalibration() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings", "General"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 2, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 1, scrollLimit: 2,
            calibrationScrollLimit: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        // WITHOUT skipCalibration: scroll should be blocked by exhaustion
        let explorer = BFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let graph = session.currentGraph
        graph.markScrollExhausted(fingerprint: graph.rootFingerprint)

        let rootScreen = makeScreen(["Settings", "General"])
        let screens = [ScreenDescriber.DescribeResult](repeating: rootScreen, count: 10)
        let describer = MockExplorerDescriber(screens: screens)
        let input = MockExplorerInput()

        for _ in 0..<4 {
            let result = explorer.step(
                describer: describer, input: input, strategy: MobileAppStrategy.self
            )
            if case .finished = result { break }
        }

        // Should NOT have scrolled — exhaustion blocks it
        let downSwipes = input.swipes.filter { $0.fromY > $0.toY }
        XCTAssertEqual(downSwipes.count, 0,
            "Scroll-exhausted screen should not scroll when skipCalibration is false")
    }
}
