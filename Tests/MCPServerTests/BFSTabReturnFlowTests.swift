// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for tab-aware backtracking flows: sibling-screen escalation, the
// ABOUTME: .returning-phase .tab branch, and Q-boost wiring from persisted edge values.

import CoreGraphics
import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class BFSTabReturnFlowTests: XCTestCase {

    // MARK: - Test Helpers

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

    private func makeBudget() -> ExplorationBudget {
        ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            calibrationScrollLimit: 0, skipPatterns: []
        )
    }

    private func makeTabAppDescription(tabs: [String]) -> AppDescription {
        AppDescription(
            appName: "TestApp", schemaVersion: 1, locale: "fr_CA", archetype: nil, playable: nil,
            resetBeforeExplore: false, obstacleMode: .auto, context: "test",
            obstacles: [], skipElements: [], credentials: [:], hints: [],
            tabs: tabs, tabLayout: TabLayout(orientation: .horizontal, edge: .bottom),
            deepTabs: [], simulator: nil
        )
    }

    private let bandIcons = [
        IconDetector.DetectedIcon(tapX: 142, tapY: 846, estimatedSize: 24),
        IconDetector.DetectedIcon(tapX: 206, tapY: 846, estimatedSize: 30),
        IconDetector.DetectedIcon(tapX: 343, tapY: 846, estimatedSize: 27),
    ]

    /// Session on an icon-only tab screen: root captured, then a tab screen
    /// whose node carries detected band icons but no tab text labels.
    private func setupTabSession() -> ExplorationSession {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")
        session.setAppDescription(makeTabAppDescription(
            tabs: ["Accueil", "Recherche", "Reels", "Boutique", "Profil"]))
        session.capture(
            elements: makeElements(["General", "Privacy"]), hints: [],
            icons: [], actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )
        session.capture(
            elements: makeElements(["Video feed", "Trending"]), hints: [],
            icons: bandIcons, actionType: "tap", arrivedVia: "Reels",
            screenshotBase64: "imgTab"
        )
        return session
    }

    // MARK: - Known Sibling Overrides Tab-Bar Evidence

    func testTabReturnLandingOnKnownSiblingEscalatesToRootReset() {
        // The return tap drops and the explorer stays on the KNOWN sibling tab
        // screen. Tab-bar evidence is true on every tab screen, so it must NOT
        // override the concrete structural match to a non-root node — the
        // explorer escalates to a genuine root reposition instead of silently
        // declaring itself at root.
        let session = setupTabSession()
        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint

        let explorer = BFSExplorer(
            session: session, budget: makeBudget(),
            windowSize: CGSize(width: 410, height: 898)
        )
        explorer.markStarted()

        let tabScreenElements = makeElements(["Video feed", "Trending"])
        let siblingScreen = ScreenDescriber.DescribeResult(
            elements: tabScreenElements,
            hints: ["\(NavigationHintDetector.tabBarHintPrefix) 5 items detected "
                + "in the bottom band — tap one to switch sections."],
            screenshotBase64: "imgTab"
        )
        let describer = MockExplorerDescriber(screens: [siblingScreen])
        let input = MockExplorerInput()

        let result = explorer.tapBackAndVerify(
            expectedFP: rootFP, afterElements: tabScreenElements,
            describer: describer, input: input, edgeType: .tab
        )

        XCTAssertNotNil(result,
            "Landing on a known non-root screen must not read as backtrack success")
        XCTAssertEqual(graph.currentFingerprint, rootFP,
            "Escalation must leave the explorer repositioned at root")
    }

    // MARK: - Returning Phase: .tab Edge

    /// Session with an icon-only tab bar visible at root, plus a sibling tab
    /// screen reached via a recorded `.tab` edge (explorer currently there).
    private func setupTabReturningSession() -> (ExplorationSession, String) {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")
        session.setAppDescription(makeTabAppDescription(
            tabs: ["Accueil", "Recherche", "Reels", "Boutique", "Profil"]))
        session.capture(
            elements: makeElements(["General", "Privacy"]), hints: [],
            icons: bandIcons, actionType: nil, arrivedVia: nil,
            screenshotBase64: "img0"
        )
        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint
        _ = graph.recordTransition(
            elements: makeElements(["Video feed", "Trending"]), icons: [],
            hints: [], screenshot: "imgTab", actionType: "tap",
            elementText: "", displayLabel: "Reels",
            screenType: .tabRoot, edgeType: .tab
        )
        return (session, rootFP)
    }

    func testStepReturningTabEdgeTapsRootTabAnchor() {
        // Reversing a .tab edge in the returning phase must tap the first
        // declared tab's synthesized anchor resolved against the source
        // screen's band icons — not an arbitrary band element.
        let (session, rootFP) = setupTabReturningSession()
        let explorer = BFSExplorer(
            session: session, budget: makeBudget(),
            windowSize: CGSize(width: 410, height: 898)
        )
        explorer.markStarted()

        let describer = MockExplorerDescriber(screens: [
            makeScreen(["Video feed", "Trending"], img: "imgTab")
        ])
        let input = MockExplorerInput()

        let result = explorer.stepReturning(
            depthRemaining: 1, describer: describer, input: input
        )

        if case .continue = result {} else {
            XCTFail("stepReturning should continue, got \(result)")
        }
        // Anchor 0 for 5 tabs on a 410-pt window: x = 0.5*410/5 = 41; the
        // cross-axis Y is the median of the source screen's band-icon Ys (846).
        XCTAssertEqual(input.taps.count, 1)
        XCTAssertEqual(input.taps.first?.x ?? -1, 41, accuracy: 2.0)
        XCTAssertEqual(input.taps.first?.y ?? -1, 846, accuracy: 2.0)
        XCTAssertEqual(session.currentGraph.currentFingerprint, rootFP,
            "Depth 1 return should land the explorer at root")
    }

    func testStepReturningTabEdgeFallsBackToSourceBandElement() {
        // No APP.md tabs declared: tapRootTab cannot resolve, so the returning
        // phase falls back to tapping the source screen's tab-zone element.
        let bandElement = TapPoint(text: "Home", tapX: 56, tapY: 850, confidence: 0.9)
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")
        session.capture(
            elements: makeElements(["General", "Privacy"]) + [bandElement],
            hints: [], icons: [], actionType: nil, arrivedVia: nil,
            screenshotBase64: "img0"
        )
        let graph = session.currentGraph
        _ = graph.recordTransition(
            elements: makeElements(["Video feed", "Trending"]), icons: [],
            hints: [], screenshot: "imgTab", actionType: "tap",
            elementText: "Home", displayLabel: "Home",
            screenType: .tabRoot, edgeType: .tab
        )
        let explorer = BFSExplorer(
            session: session, budget: makeBudget(),
            windowSize: CGSize(width: 410, height: 898)
        )
        explorer.markStarted()

        let describer = MockExplorerDescriber(screens: [
            makeScreen(["Video feed", "Trending"], img: "imgTab")
        ])
        let input = MockExplorerInput()

        _ = explorer.stepReturning(
            depthRemaining: 1, describer: describer, input: input
        )

        XCTAssertEqual(input.taps.count, 1)
        XCTAssertEqual(input.taps.first?.x ?? -1, 56, accuracy: 0.5,
            "Fallback should tap the source screen's tab-zone element")
        XCTAssertEqual(input.taps.first?.y ?? -1, 850, accuracy: 0.5)
    }

    // MARK: - Q-Value Boost Wiring

    func testApplyQBoostIfAvailableUsesPersistedEdgeValues() {
        // A dead-tap edge (qValue 0) recorded in the graph must demote its
        // plan item below an equal-scored item with the default q (1.0 → +2).
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")
        session.capture(
            elements: makeElements(["General", "Privacy"]), hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )
        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint
        _ = graph.recordTransition(
            elements: makeElements(["Detail A", "Detail B"]), icons: [],
            hints: [], screenshot: "img1", actionType: "tap",
            elementText: "General", displayLabel: "General",
            screenType: .settings, edgeType: .push
        )
        (graph as? NavigationGraph)?.updateQValue(
            fromFingerprint: rootFP, displayLabel: "General", result: .duplicate)
        graph.setCurrentFingerprint(rootFP)

        let explorer = BFSExplorer(session: session, budget: makeBudget())
        explorer.markStarted()

        let general = RankedElement(
            point: TapPoint(text: "General", tapX: 205, tapY: 200, confidence: 0.95),
            score: 5.0, reason: "nav", displayLabel: "General")
        let privacy = RankedElement(
            point: TapPoint(text: "Privacy", tapX: 205, tapY: 300, confidence: 0.95),
            score: 5.0, reason: "nav", displayLabel: "Privacy")
        let tab = RankedElement(
            point: TapPoint(text: "", tapX: 41, tapY: 846, confidence: 1.0),
            score: 6.0, reason: "tab-synth(Accueil@0,horizontal)",
            displayLabel: "Accueil", isBreadthNavigation: true)

        let boosted = explorer.applyQBoostIfAvailable(
            plan: [tab, general, privacy], fingerprint: rootFP)

        XCTAssertEqual(boosted.map { $0.displayLabel }, ["Accueil", "Privacy", "General"],
            "Breadth stays in front; dead-tap edge (q=0) demotes General below Privacy")
    }
}
