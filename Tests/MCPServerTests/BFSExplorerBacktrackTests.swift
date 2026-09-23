// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for BFSExplorer backtracking: YOLO icon dismiss and tab-aware backtracking.
// ABOUTME: Verifies deferred items when the scroll budget is exhausted.

import CoreGraphics
import XCTest
@testable import HelperLib
@testable import mirroir_mcp

extension BFSExplorerTests {

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

    // MARK: - Tab-Aware Backtracking

    private func makeTabAppDescription(tabs: [String]) -> AppDescription {
        AppDescription(
            appName: "TestApp", schemaVersion: 1, locale: "fr_CA", archetype: nil,
            resetBeforeExplore: false, obstacleMode: .auto, context: "test",
            obstacles: [], skipElements: [], credentials: [:], hints: [],
            tabs: tabs, tabLayout: TabLayout(orientation: .horizontal, edge: .bottom),
            deepTabs: [], simulator: nil
        )
    }

    /// Session on an icon-only tab screen: root captured, then a tab screen
    /// whose node carries detected band icons but no tab text labels.
    private func setupTabSession() -> ExplorationSession {
        let session = setupSession(rootTexts: ["General", "Privacy"])
        session.setAppDescription(makeTabAppDescription(
            tabs: ["Accueil", "Recherche", "Reels", "Boutique", "Profil"]))
        let bandIcons = [
            IconDetector.DetectedIcon(tapX: 142, tapY: 846, estimatedSize: 24),
            IconDetector.DetectedIcon(tapX: 206, tapY: 846, estimatedSize: 30),
            IconDetector.DetectedIcon(tapX: 343, tapY: 846, estimatedSize: 27),
        ]
        session.capture(
            elements: makeElements(["Video feed", "Trending"]), hints: [],
            icons: bandIcons, actionType: "tap", arrivedVia: "Reels",
            screenshotBase64: "imgTab"
        )
        return session
    }

    func testTabEdgeBacktrackTapsFirstDeclaredTab() {
        // Icon-only tab bar (Instagram-style): a .tab-edge backtrack must tap
        // the first APP.md-declared tab's synthesized anchor — NOT the blind
        // back-button fallback at (46,120), which lands in the stories row.
        let session = setupTabSession()
        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint

        let explorer = BFSExplorer(
            session: session, budget: makeBudget(),
            windowSize: CGSize(width: 410, height: 898)
        )
        explorer.markStarted()

        // The return lands on the root screen — fingerprint verifies directly.
        let describer = MockExplorerDescriber(screens: [
            makeScreen(["General", "Privacy"], img: "img0")
        ])
        let input = MockExplorerInput()

        let result = explorer.tapBackAndVerify(
            expectedFP: rootFP, afterElements: makeElements(["Video feed", "Trending"]),
            describer: describer, input: input, edgeType: .tab
        )

        XCTAssertNil(result, "Tab return should verify against the root screen")
        // Synthesized anchor 0 for 5 tabs on a 410-pt-wide window:
        // x = (0+0.5)*410/5 = 41, y = median of detected band-icon Ys (846).
        let firstTap = input.taps.first
        XCTAssertEqual(firstTap?.x ?? -1, 41, accuracy: 2.0,
            "Root-tab tap should land on synthesized anchor index 0")
        XCTAssertEqual(firstTap?.y ?? -1, 846, accuracy: 2.0,
            "Root-tab tap should use the detected icon-band Y")
        XCTAssertFalse(
            input.taps.contains { abs($0.x - 46) < 2 && abs($0.y - 120) < 2 },
            "Must not blind-tap the back-button fallback (stories row)"
        )
    }

    func testTabReturnAcceptsTabBarEvidenceOnFingerprintDrift() {
        // Feed content churns between visits, so the root tab re-fingerprints
        // on every return. Tab-bar evidence (hint present, no back chevron)
        // must be accepted as at-root instead of escalating to AppRootNavigator.
        let session = setupTabSession()
        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint

        let explorer = BFSExplorer(
            session: session, budget: makeBudget(),
            windowSize: CGSize(width: 410, height: 898)
        )
        explorer.markStarted()

        // The return lands on churned feed content: unknown fingerprint, but
        // the tab-bar hint is present and no back chevron was detected.
        let driftedScreen = ScreenDescriber.DescribeResult(
            elements: makeElements(["Nouveau post", "Story du jour"]),
            hints: ["\(NavigationHintDetector.tabBarHintPrefix) 5 items detected "
                + "in the bottom band — tap one to switch sections."],
            screenshotBase64: "imgDrift"
        )
        let describer = MockExplorerDescriber(screens: [driftedScreen])
        let input = MockExplorerInput()

        let result = explorer.tapBackAndVerify(
            expectedFP: rootFP, afterElements: makeElements(["Video feed", "Trending"]),
            describer: describer, input: input, edgeType: .tab
        )

        XCTAssertNil(result, "Drifted tab return with tab-bar evidence should be accepted")
        XCTAssertEqual(graph.currentFingerprint, rootFP,
            "Explorer should treat the drifted screen as the tab root")
        XCTAssertTrue(input.launches.isEmpty,
            "Tab-bar evidence must prevent AppRootNavigator Spotlight escalation")
        // The drift must be accepted on the FIRST post-return OCR — before the
        // recovery ladder, whose blind fallback back-taps land in feed content.
        XCTAssertEqual(input.taps.count, 1,
            "Only the root-tab return tap may run — no recovery-ladder taps")
        XCTAssertEqual(input.taps.first?.x ?? -1, 41, accuracy: 2.0)
        XCTAssertEqual(input.taps.first?.y ?? -1, 846, accuracy: 2.0)
    }
}
