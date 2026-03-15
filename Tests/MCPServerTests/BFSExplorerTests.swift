// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for BFSExplorer: layer-by-layer exploration, path replay, budget limits.
// ABOUTME: Verifies BFS explores all elements at each depth before going deeper.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class BFSExplorerTests: XCTestCase {

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

    private func makeBudget(
        maxDepth: Int = 6, maxScreens: Int = 30, maxTime: Int = 300,
        maxActions: Int = 5, scrollLimit: Int = 0, calibrationScrollLimit: Int = 0,
        skipPatterns: [String] = []
    ) -> ExplorationBudget {
        ExplorationBudget(
            maxDepth: maxDepth, maxScreens: maxScreens, maxTimeSeconds: maxTime,
            maxActionsPerScreen: maxActions, scrollLimit: scrollLimit,
            calibrationScrollLimit: calibrationScrollLimit,
            skipPatterns: skipPatterns
        )
    }

    private func makeExplorer(
        session: ExplorationSession, budget: ExplorationBudget
    ) -> BFSExplorer {
        let explorer = BFSExplorer(session: session, budget: budget)
        explorer.markStarted()
        return explorer
    }

    private func setupSession(rootTexts: [String]) -> ExplorationSession {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")
        let rootElements = makeElements(rootTexts)
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )
        return session
    }

    // MARK: - Root Exploration

    func testBFSExploresRootElementsFirst() {
        let session = setupSession(rootTexts: ["General", "Privacy"])
        let explorer = makeExplorer(session: session, budget: makeBudget())

        let root = makeScreen(["General", "Privacy"], img: "img0")
        let describer = MockExplorerDescriber(screens: [
            root, makeScreen(["Version", "Build"], img: "imgA"), root,      // step1: tap General → backtrack verify
            root, makeScreen(["Location", "Tracking"], img: "imgB"), root,  // step2: tap Privacy → backtrack verify
            root,                                                           // step3: done
        ])
        let input = MockExplorerInput()

        let step1 = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        guard case .continue(let d1) = step1 else {
            return XCTFail("Expected .continue for step 1, got \(step1)")
        }
        XCTAssertTrue(d1.contains("new screen"), "Step 1 should discover new screen")

        let step2 = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        guard case .continue(let d2) = step2 else {
            return XCTFail("Expected .continue for step 2, got \(step2)")
        }
        XCTAssertTrue(d2.contains("new screen"), "Step 2 should discover new screen")

        let step3 = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        guard case .continue(let d3) = step3 else {
            return XCTFail("Expected .continue for step 3, got \(step3)")
        }
        XCTAssertTrue(d3.contains("Finished exploring"), "Got: \(d3)")
        XCTAssertEqual(explorer.stats.nodeCount, 3, "Should have root + 2 child screens")
    }

    // MARK: - Layer-by-Layer Order

    func testBFSGoesLayerByLayer() {
        let session = setupSession(rootTexts: ["ItemA", "ItemB"])
        let explorer = makeExplorer(session: session, budget: makeBudget())

        let root = makeScreen(["ItemA", "ItemB"], img: "img0")
        let screenA = makeScreen(["SubA1"], img: "imgA")
        let screenB = makeScreen(["SubB1"], img: "imgB")
        let describer = MockExplorerDescriber(screens: [
            root, screenA, root,                          // step1: tap ItemA → backtrack verify
            root, screenB, root,                          // step2: tap ItemB → backtrack verify
            root,                                         // step3: done with root
            screenA,                                      // step4: navigate to ItemA
        ])
        let input = MockExplorerInput()

        for _ in 0..<3 {
            _ = explorer.step(
                describer: describer, input: input, strategy: MobileAppStrategy.self)
        }
        XCTAssertEqual(explorer.stats.nodeCount, 3, "root + 2 children after root exploration")

        // Step 4: should navigate to depth-1 screen (not explore depth-2)
        let step4 = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        guard case .continue(let d4) = step4 else {
            return XCTFail("Expected .continue for step 4, got \(step4)")
        }
        XCTAssertTrue(d4.contains("Navigated") || d4.contains("depth-1"), "Got: \(d4)")
    }

    // MARK: - No Duplicate Taps

    func testBFSNeverClicksSameElementTwice() {
        let session = setupSession(rootTexts: ["General", "Privacy", "About"])
        let budget = makeBudget()
        let explorer = makeExplorer(session: session, budget: budget)

        let root = makeScreen(["General", "Privacy", "About"], img: "img0")
        let childA = makeScreen(["Version"], img: "imgA")
        let childB = makeScreen(["Location"], img: "imgB")
        let childC = makeScreen(["Model"], img: "imgC")

        let describer = MockExplorerDescriber(screens: [
            root, childA, root,    // step1: tap General → backtrack verify
            root, childB, root,    // step2: tap Privacy → backtrack verify
            root, childC, root,    // step3: tap About → backtrack verify
            root,                  // step4: no more elements
        ])
        let input = MockExplorerInput()

        for _ in 0..<4 {
            _ = explorer.step(
                describer: describer, input: input, strategy: MobileAppStrategy.self
            )
        }

        // Verify: each root element tapped exactly once (forward taps only).
        // Forward taps are at X=205 (element center); back-button taps are at X≈46 (nav bar).
        let forwardTaps = input.taps.filter { $0.x > 100 }
        let tappedYs = forwardTaps.map { $0.y }
        let uniqueYs = Set(tappedYs)
        XCTAssertEqual(
            tappedYs.count, uniqueYs.count,
            "Each element should be tapped at a unique Y position (no duplicates). " +
            "Forward taps: \(forwardTaps.count), unique Ys: \(uniqueYs.count)"
        )
    }

    // MARK: - Deep Navigation via Path Replay

    func testBFSNavigatesToDeepScreen() {
        let session = setupSession(rootTexts: ["General"])
        let explorer = makeExplorer(session: session, budget: makeBudget(maxDepth: 3))

        let root = makeScreen(["General"], img: "img0")
        let gen = makeScreen(["About"], img: "imgG")
        let about = makeScreen(["Model", "Version"], img: "imgA")
        let describer = MockExplorerDescriber(screens: [
            root, gen, root,      // step1: root → tap General → backtrack verify
            root,                 // step2: root done
            gen,                  // step3: navigate to General
            gen, about, gen,      // step4: explore General → tap About → backtrack verify
            gen,                  // step5: General done
            gen,                  // step6: returning → tap back
            gen,                  // step7: navigate to About: tap General
            about,                // step8: navigate to About: tap About
        ])
        let input = MockExplorerInput()

        for _ in 0..<8 {
            let result = explorer.step(
                describer: describer, input: input, strategy: MobileAppStrategy.self)
            if case .finished = result { break }
            if case .paused = result { break }
        }
        XCTAssertEqual(explorer.stats.nodeCount, 3, "root + General + About")
    }

    // MARK: - Return to Root

    func testBFSReturnsToRootAfterExploring() {
        let session = setupSession(rootTexts: ["General"])
        let explorer = makeExplorer(session: session, budget: makeBudget())

        let root = makeScreen(["General"], img: "img0")
        let gen = makeScreen(["About"], img: "imgG")
        let describer = MockExplorerDescriber(screens: [
            root, gen, root,                                      // step1: root → tap General → backtrack verify
            root,                                                 // step2: root done
            gen,                                                  // step3: navigate to General
            gen, makeScreen(["Model"], img: "imgA"), gen,          // step4: explore General → tap About → backtrack verify
            gen,                                                  // step5: General done
            gen,                                                  // step6: returning → tap back
        ])
        let input = MockExplorerInput()

        var results: [ExploreStepResult] = []
        for _ in 0..<6 {
            let result = explorer.step(
                describer: describer, input: input, strategy: MobileAppStrategy.self)
            results.append(result)
            if case .finished = result { break }
        }

        let hasReturnStep = results.contains { result in
            if case .continue(let d) = result { return d.contains("Returning to root") }
            return false
        }
        XCTAssertTrue(hasReturnStep, "Should have a returning-to-root step")
        let backTaps = input.taps.filter { $0.x < 60 && $0.y < 140 }
        XCTAssertGreaterThanOrEqual(backTaps.count, 1, "Should tap back from depth-1")
    }

    // MARK: - Max Depth

    func testBFSRespectsMaxDepth() {
        let session = setupSession(rootTexts: ["General"])
        let explorer = makeExplorer(session: session, budget: makeBudget(maxDepth: 1))

        let root = makeScreen(["General"], img: "img0")
        let describer = MockExplorerDescriber(screens: [
            root, makeScreen(["About", "Version"], img: "imgG"), // step1: tap General
            root,                                                 // step2: root done
        ])
        let input = MockExplorerInput()

        _ = explorer.step(describer: describer, input: input, strategy: MobileAppStrategy.self)
        _ = explorer.step(describer: describer, input: input, strategy: MobileAppStrategy.self)

        // Frontier should be empty (depth-1 screen not queued because maxDepth=1)
        let step3 = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        if case .finished = step3 { /* expected */ }
        else { XCTFail("Expected .finished when maxDepth reached, got \(step3)") }
    }

    // MARK: - Max Screens

    func testBFSRespectsMaxScreens() {
        let session = setupSession(rootTexts: ["General", "Privacy", "About"])
        let explorer = makeExplorer(session: session, budget: makeBudget(maxScreens: 2))

        let root = makeScreen(["General", "Privacy", "About"], img: "img0")
        let describer = MockExplorerDescriber(screens: [
            root, makeScreen(["Version"], img: "imgA"),   // step1: tap → 2 screens = maxScreens
            root, makeScreen(["Location"], img: "imgB"),  // step2: budget exhausted
        ])
        let input = MockExplorerInput()

        let step1 = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        guard case .continue = step1 else {
            return XCTFail("Expected .continue for step 1, got \(step1)")
        }
        let step2 = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        if case .finished = step2 { /* expected */ }
        else { XCTFail("Expected .finished when maxScreens reached, got \(step2)") }
    }

    // MARK: - Non-Navigating Element

    func testBFSHandlesNonNavigatingElement() {
        let session = setupSession(rootTexts: ["General", "Toggle"])
        let explorer = makeExplorer(session: session, budget: makeBudget())

        let root = makeScreen(["General", "Toggle"], img: "img0")
        let describer = MockExplorerDescriber(screens: [
            root, root,                                    // step1: tap → same screen
            root, makeScreen(["Version"], img: "imgA"),    // step2: tap → new
            root,                                          // step3: done
        ])
        let input = MockExplorerInput()

        let step1 = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        guard case .continue(let d1) = step1 else {
            return XCTFail("Expected .continue for step 1, got \(step1)")
        }
        XCTAssertTrue(d1.contains("dead tap") || d1.contains("no navigation") || d1.contains("new screen"), "Got: \(d1)")
        XCTAssertFalse(explorer.completed, "Should continue after non-navigating tap")
    }

    // MARK: - Finished When Frontier Empty

    func testBFSFinishesWhenFrontierEmpty() {
        let session = setupSession(rootTexts: ["AB"])
        let explorer = makeExplorer(session: session, budget: makeBudget())

        // "AB" is 2 chars → filtered as decoration (landmarkMinLength=3) → no actionable
        let describer = MockExplorerDescriber(screens: [makeScreen(["AB"], img: "img0")])
        let input = MockExplorerInput()

        var result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        if case .continue = result {
            result = explorer.step(
                describer: describer, input: input, strategy: MobileAppStrategy.self)
        }
        if case .finished = result { /* expected */ }
        else { XCTFail("Expected .finished with no navigable elements, got \(result)") }
        XCTAssertEqual(input.taps.count, 0, "Should not tap any elements")
    }

    // MARK: - Budget: Time Exhaustion

    func testBFSFinishesWhenTimeExhausted() {
        let session = setupSession(rootTexts: ["General"])
        let explorer = makeExplorer(session: session, budget: makeBudget(maxTime: 0))
        let describer = MockExplorerDescriber(screens: [makeScreen(["General"])])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        if case .finished = result { /* expected */ }
        else { XCTFail("Expected .finished when time exhausted, got \(result)") }
    }

    // MARK: - OCR Failure

    func testBFSPausesOnOCRFailure() {
        let session = setupSession(rootTexts: ["General"])
        let explorer = makeExplorer(session: session, budget: makeBudget())
        let describer = MockExplorerDescriber(screens: [])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        if case .paused(let reason) = result {
            XCTAssertTrue(reason.contains("Failed"), "Got: \(reason)")
        } else { XCTFail("Expected .paused on OCR failure, got \(result)") }
    }

    // MARK: - Skip Patterns

    func testBFSSkipsDangerousElements() {
        let session = setupSession(rootTexts: ["Sign Out"])
        let budget = makeBudget(skipPatterns: ["Sign Out"])
        let explorer = makeExplorer(session: session, budget: budget)
        let describer = MockExplorerDescriber(screens: [makeScreen(["Sign Out"])])
        let input = MockExplorerInput()

        var result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)
        while case .continue = result {
            result = explorer.step(
                describer: describer, input: input, strategy: MobileAppStrategy.self)
        }
        if case .finished = result { /* expected */ }
        else { XCTFail("Expected .finished when only element is skippable, got \(result)") }
        XCTAssertEqual(input.taps.count, 0, "Should not tap dangerous elements")
    }

    // MARK: - Stats and State

    func testBFSStatsTrackProgress() {
        let session = setupSession(rootTexts: ["General"])
        let explorer = makeExplorer(session: session, budget: makeBudget())
        let stats = explorer.stats
        XCTAssertEqual(stats.nodeCount, 1, "Should have 1 node from initial capture")
        XCTAssertEqual(stats.actionCount, 0, "No actions taken yet")
        XCTAssertGreaterThanOrEqual(stats.elapsedSeconds, 0)
    }

    func testBFSCompletedInitiallyFalse() {
        let session = setupSession(rootTexts: ["General"])
        let explorer = BFSExplorer(session: session, budget: makeBudget())
        XCTAssertFalse(explorer.completed, "Explorer should not be completed initially")
    }

    // MARK: - Backtrack: YOLO Icon Dismiss

    func testBacktrackDismissesModalWithYOLOIcon() {
        // When a modal has no back chevron but has a YOLO "icon" in the top-right
        // (common in iOS Health article modals), the backtrack verifier should
        // recognize it as a dismiss button and tap it.
        let session = setupSession(rootTexts: ["General", "Privacy"])
        let explorer = makeExplorer(session: session, budget: makeBudget())
        let rootFP = session.currentGraph.rootFingerprint

        // Modal screen: article with YOLO icon dismiss button at top-right.
        // "icon" is what YOLO reports for unlabeled UI icons (like X dismiss buttons).
        let modalElements = [
            TapPoint(text: "Article sur le sommeil", tapX: 210, tapY: 137, confidence: 0.95),
            TapPoint(text: "icon", tapX: 350, tapY: 137, confidence: 0.90),
        ]
        let modalScreen = ScreenDescriber.DescribeResult(
            elements: modalElements, screenshotBase64: "modal"
        )

        // Parent screen after dismiss — must match root fingerprint's elements
        let parentScreen = makeScreen(["General", "Privacy"], img: "parent")

        // Describer sequence: modal (OCR after back), parent (OCR after dismiss)
        let describer = MockExplorerDescriber(screens: [modalScreen, parentScreen])
        let input = MockExplorerInput()

        let result = explorer.verifyBacktrack(
            expectedFP: rootFP,
            afterElements: modalElements,
            describer: describer,
            input: input
        )

        if case .verified = result { /* expected */ }
        else { XCTFail("Expected .verified after YOLO icon dismiss, got \(result)") }

        // Verify the dismiss tap was at the icon's coordinates
        let hasDismissTap = input.taps.contains { Int($0.x) == 350 && Int($0.y) == 137 }
        XCTAssertTrue(hasDismissTap, "Should have tapped the icon at (350, 137)")
    }

    func testBacktrackIgnoresYOLOIconOnLeftSide() {
        // A YOLO "icon" in the top-LEFT should NOT be treated as a dismiss button.
        // Only top-RIGHT icons (right half of screen) are candidates for dismiss.
        let session = setupSession(rootTexts: ["General", "Privacy"])
        let explorer = makeExplorer(session: session, budget: makeBudget())
        let rootFP = session.currentGraph.rootFingerprint

        // Modal screen with icon on the LEFT side (x=40 is < 205 = width/2)
        let modalElements = [
            TapPoint(text: "Some Title", tapX: 210, tapY: 137, confidence: 0.95),
            TapPoint(text: "icon", tapX: 40, tapY: 137, confidence: 0.90),
        ]
        let modalScreen = ScreenDescriber.DescribeResult(
            elements: modalElements, screenshotBase64: "modal"
        )

        // After failed dismiss recovery, verifier retries back button + checks known screens.
        // Return the modal again (still stuck) so it falls through to .lost.
        let describer = MockExplorerDescriber(screens: [modalScreen, modalScreen, modalScreen])
        let input = MockExplorerInput()

        let result = explorer.verifyBacktrack(
            expectedFP: rootFP,
            afterElements: modalElements,
            describer: describer,
            input: input
        )

        if case .lost = result { /* expected — icon on left side not treated as dismiss */ }
        else { XCTFail("Expected .lost when icon is on left side, got \(result)") }
    }

    // MARK: - Scroll Budget: Deferred Items

    func testResolveDefersItemsWhenScrollBudgetExhausted() {
        // When resolveNextPlanItem's scroll budget is exhausted, items that need
        // scrolling should NOT be marked as visited. They stay in the plan so
        // performScrollIfAvailable can scroll and make them reachable later.
        let session = setupSession(rootTexts: ["Visible", "Hidden1", "Hidden2"])
        let budget = makeBudget(scrollLimit: 0)  // 0 = no resolve scrolls allowed
        let explorer = makeExplorer(session: session, budget: budget)

        let graph = session.currentGraph
        let fp = graph.currentFingerprint

        // Set a plan with 3 items: "Visible" at y=120, "Hidden1"/"Hidden2" at y=200/280
        let plan = [
            RankedElement(point: TapPoint(text: "Visible", tapX: 205, tapY: 120, confidence: 0.95),
                          score: 5.0, reason: "test"),
            RankedElement(point: TapPoint(text: "Hidden1", tapX: 205, tapY: 200, confidence: 0.95),
                          score: 4.0, reason: "test"),
            RankedElement(point: TapPoint(text: "Hidden2", tapX: 205, tapY: 280, confidence: 0.95),
                          score: 3.0, reason: "test"),
        ]
        graph.setScreenPlan(for: fp, plan: plan)

        // Viewport only contains "Visible" — "Hidden1"/"Hidden2" are below fold
        let viewportElements = [
            TapPoint(text: "Visible", tapX: 205, tapY: 120, confidence: 0.95)
        ]

        let describer = MockExplorerDescriber(screens: [])
        let input = MockExplorerInput()

        // First resolve: should find "Visible" (in viewport)
        let result1 = explorer.resolveNextPlanItem(
            currentFP: fp, viewportElements: viewportElements,
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )
        XCTAssertEqual(result1?.displayLabel, "Visible", "Should resolve 'Visible' from viewport")

        // Mark "Visible" as visited (simulating what step() does after tapping)
        graph.markElementVisited(fingerprint: fp, elementText: "Visible")

        // Second resolve: "Hidden1" needs scroll, budget=0 → should return nil without consuming it
        let result2 = explorer.resolveNextPlanItem(
            currentFP: fp, viewportElements: viewportElements,
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )
        XCTAssertNil(result2, "Should return nil when next item needs scroll and budget exhausted")

        // Verify "Hidden1" and "Hidden2" are NOT visited — they're still in the plan
        let visited = graph.node(for: fp)?.visitedElements ?? []
        XCTAssertFalse(visited.contains("Hidden1"),
            "Hidden1 should NOT be marked visited when scroll budget exhausted")
        XCTAssertFalse(visited.contains("Hidden2"),
            "Hidden2 should NOT be marked visited — it was never even reached")

        // Verify the plan still has unvisited items available
        let nextItem = graph.nextPlannedElement(for: fp)
        XCTAssertEqual(nextItem?.displayLabel, "Hidden1",
            "Hidden1 should still be the next planned element")
    }
}
