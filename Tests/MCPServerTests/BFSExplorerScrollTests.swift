// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for action counter reset after scroll in BFS and DFS explorers.
// ABOUTME: Verifies that scrolling resets the per-screen action counter so new elements get tapped.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class BFSExplorerScrollTests: XCTestCase {

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        makeExplorerElements(texts, startY: startY)
    }

    private func makeScreen(
        _ texts: [String], startY: Double = 120, img: String = "img"
    ) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: makeElements(texts, startY: startY), screenshotBase64: img
        )
    }

    // MARK: - BFS: Action Counter Reset After Scroll

    /// After 5 taps exhaust maxActionsPerScreen, a scroll that finds new elements
    /// should reset the counter so the explorer taps the newly discovered elements.
    func testBFSResetsActionCounterAfterScroll() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Root has 6 elements but only 5 can be tapped before the action limit.
        // The 6th ("Mood") will only be reachable if scroll resets the counter.
        let rootElements = makeElements(
            ["Activity", "Heart", "Sleep", "Steps", "Nutrition"]
        )
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 2, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 1,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )
        let explorer = BFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // The 6th element appears after scrolling
        let scrolledElements = makeElements(
            ["Activity", "Heart", "Sleep", "Steps", "Nutrition", "Mood"],
            startY: 120
        )
        let moodScreen = makeScreen(["Mood Details"], img: "imgMood")

        // Build the describe sequence:
        // Calibration: 1 OCR call (scroll discovers no new elements → breaks)
        // Steps 1-5: each step does 2 OCR calls (before-tap + after-tap)
        // For simplicity, all taps produce "duplicate" (same screen fingerprint).
        var screens: [ScreenDescriber.DescribeResult] = []
        let rootScreen = makeScreen(
            ["Activity", "Heart", "Sleep", "Steps", "Nutrition"], img: "img0"
        )

        // Calibration scroll: discovers same elements → 0 new → breaks
        screens.append(rootScreen)

        // Steps 1-5: tap each of the 5 initial elements → duplicate (same screen)
        for _ in 0..<5 {
            screens.append(rootScreen)  // OCR before tap
            screens.append(rootScreen)  // OCR after tap → duplicate
        }

        // Step 6: guard fails (5 actions) → scroll
        screens.append(rootScreen)  // OCR at start of stepExploring
        // performScrollIfAvailable does its own OCR after swipe:
        let scrolledScreen = ScreenDescriber.DescribeResult(
            elements: scrolledElements, screenshotBase64: "img0_scrolled"
        )
        screens.append(scrolledScreen)  // OCR after scroll → finds "Mood"

        // Step 7: action counter reset, explorer re-OCRs and taps "Mood"
        let rootWithMood = ScreenDescriber.DescribeResult(
            elements: scrolledElements, screenshotBase64: "img0_scrolled"
        )
        screens.append(rootWithMood)   // OCR before tap
        screens.append(moodScreen)     // OCR after tap → new screen

        // Step 8: done exploring root
        screens.append(rootWithMood)

        let describer = MockExplorerDescriber(screens: screens)
        let input = MockExplorerInput()

        var results: [ExploreStepResult] = []
        for _ in 0..<8 {
            let result = explorer.step(
                describer: describer, input: input, strategy: MobileAppStrategy.self
            )
            results.append(result)
            if case .finished = result { break }
        }

        // Verify a scroll happened
        XCTAssertGreaterThanOrEqual(input.swipes.count, 1, "Should have scrolled at least once")

        // Verify "Mood" was tapped after scroll reset the counter.
        // Forward taps are at X=205; back taps are at X≈46.
        let forwardTaps = input.taps.filter { $0.x > 100 }
        XCTAssertGreaterThan(forwardTaps.count, 5,
            "Should tap more than 5 elements (scroll revealed new ones). Got \(forwardTaps.count)")

        // Verify the scroll result was reported
        let scrollResults = results.filter {
            if case .continue(let d) = $0 { return d.contains("Scrolled") }
            return false
        }
        XCTAssertEqual(scrollResults.count, 1, "Should have exactly one scroll step")
    }

    // MARK: - DFS: Action Counter Reset After Scroll

    /// Same test for DFS: after exhausting actions, scroll finds new elements,
    /// counter resets, and the explorer taps the new element instead of backtracking.
    func testDFSResetsActionCounterAfterScroll() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings", "General"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 1, scrollLimit: 1,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let rootScreen = ScreenDescriber.DescribeResult(
            elements: rootElements, screenshotBase64: "img0"
        )

        // Step 1: tap "Settings" → duplicate (no navigation)
        let describer1 = MockExplorerDescriber(screens: [
            rootScreen,  // dismissAlertIfPresent OCR
            rootScreen,  // performTap: after-tap OCR
        ])
        let input = MockExplorerInput()

        let step1 = explorer.step(
            describer: describer1, input: input, strategy: MobileAppStrategy.self
        )
        guard case .continue = step1 else {
            return XCTFail("Expected .continue for step 1, got \(step1)")
        }

        // Now actionsOnCurrentScreen=1 (at limit). Next step should scroll.
        // Scroll reveals a new element "About"
        let scrolledElements = makeElements(["Settings", "General", "About"])
        let scrolledScreen = ScreenDescriber.DescribeResult(
            elements: scrolledElements, screenshotBase64: "img0_scrolled"
        )

        let describer2 = MockExplorerDescriber(screens: [
            rootScreen,      // dismissAlertIfPresent OCR (sees Settings, General — both visited/at limit)
            scrolledScreen,  // performScrollIfAvailable: after-scroll OCR → finds "About"
        ])

        let step2 = explorer.step(
            describer: describer2, input: input, strategy: MobileAppStrategy.self
        )
        guard case .continue(let d2) = step2 else {
            return XCTFail("Expected .continue for step 2 (scroll), got \(step2)")
        }
        XCTAssertTrue(d2.contains("Scrolled"), "Should scroll. Got: \(d2)")

        // Step 3: counter is reset, should tap "About" (the new element)
        let aboutScreen = makeScreen(["About Version"], img: "imgAbout")
        let describer3 = MockExplorerDescriber(screens: [
            scrolledScreen,  // dismissAlertIfPresent OCR
            aboutScreen,     // performTap: after-tap OCR → new screen
        ])

        let step3 = explorer.step(
            describer: describer3, input: input, strategy: MobileAppStrategy.self
        )
        guard case .continue(let d3) = step3 else {
            return XCTFail("Expected .continue for step 3, got \(step3)")
        }
        XCTAssertTrue(d3.contains("new screen") || d3.contains("Tapped"),
            "Should tap a new element after scroll reset. Got: \(d3)")

        // Verify scroll happened
        XCTAssertEqual(input.swipes.count, 1, "Should have scrolled exactly once")
    }

    // MARK: - Scroll Budget Still Enforced

    /// Even with action counter reset, the scroll count still increments
    /// and respects scrollLimit. After 3 scrolls, no more scrolls happen.
    func testScrollBudgetStillEnforced() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["ItemA"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 1, scrollLimit: 2,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let graph = session.currentGraph

        // Pre-visit the only element so the explorer immediately tries to scroll
        graph.markElementVisited(
            fingerprint: graph.currentFingerprint, elementText: "ItemA"
        )

        let rootScreen = ScreenDescriber.DescribeResult(
            elements: rootElements, screenshotBase64: "img0"
        )
        // Each scroll discovers one new element
        let scroll1Elements = makeElements(["ItemA", "ItemB"])
        let scroll1Screen = ScreenDescriber.DescribeResult(
            elements: scroll1Elements, screenshotBase64: "img_s1"
        )
        let scroll2Elements = makeElements(["ItemA", "ItemB", "ItemC"])
        let scroll2Screen = ScreenDescriber.DescribeResult(
            elements: scroll2Elements, screenshotBase64: "img_s2"
        )

        let input = MockExplorerInput()

        // Step 1: all visited → scroll #1 → finds ItemB
        let describer1 = MockExplorerDescriber(screens: [
            rootScreen,    // dismissAlertIfPresent OCR
            scroll1Screen, // after-scroll OCR → novel
        ])
        let step1 = explorer.step(
            describer: describer1, input: input, strategy: MobileAppStrategy.self
        )
        guard case .continue(let d1) = step1 else {
            return XCTFail("Expected .continue for scroll 1, got \(step1)")
        }
        XCTAssertTrue(d1.contains("Scrolled"), "Should scroll #1. Got: \(d1)")

        // Step 2: tap ItemB → duplicate
        let describer2 = MockExplorerDescriber(screens: [
            scroll1Screen, // dismissAlertIfPresent
            scroll1Screen, // after-tap → duplicate
        ])
        let step2 = explorer.step(
            describer: describer2, input: input, strategy: MobileAppStrategy.self
        )
        guard case .continue = step2 else {
            return XCTFail("Expected .continue for tap, got \(step2)")
        }

        // Step 3: all visited again → scroll #2 → finds ItemC
        graph.markElementVisited(
            fingerprint: graph.currentFingerprint, elementText: "ItemB"
        )
        let describer3 = MockExplorerDescriber(screens: [
            scroll1Screen, // dismissAlertIfPresent
            scroll2Screen, // after-scroll OCR → novel
        ])
        let step3 = explorer.step(
            describer: describer3, input: input, strategy: MobileAppStrategy.self
        )
        guard case .continue(let d3) = step3 else {
            return XCTFail("Expected .continue for scroll 2, got \(step3)")
        }
        XCTAssertTrue(d3.contains("Scrolled"), "Should scroll #2. Got: \(d3)")

        // Step 4: tap ItemC → duplicate
        let describer4 = MockExplorerDescriber(screens: [
            scroll2Screen,
            scroll2Screen,
        ])
        let step4 = explorer.step(
            describer: describer4, input: input, strategy: MobileAppStrategy.self
        )
        guard case .continue = step4 else {
            return XCTFail("Expected .continue for tap, got \(step4)")
        }

        // Step 5: all visited, scroll budget (2) exhausted → should finish (root, no backtrack)
        graph.markElementVisited(
            fingerprint: graph.currentFingerprint, elementText: "ItemC"
        )
        let describer5 = MockExplorerDescriber(screens: [
            scroll2Screen,
        ])
        let step5 = explorer.step(
            describer: describer5, input: input, strategy: MobileAppStrategy.self
        )
        if case .finished = step5 {
            // Expected: scroll budget exhausted, at root, nothing left
        } else {
            XCTFail("Expected .finished after scroll budget exhausted, got \(step5)")
        }

        // Verify exactly 2 scrolls happened (not more)
        XCTAssertEqual(input.swipes.count, 2,
            "Should have scrolled exactly twice (scrollLimit=2)")
    }
}
