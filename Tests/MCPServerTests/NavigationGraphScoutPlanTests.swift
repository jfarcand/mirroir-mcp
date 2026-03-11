// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for NavigationGraph scout phase, screen plan, backtrack sync, and root accessors.
// ABOUTME: Covers traversal phases, planned element ordering, fingerprint sync, and edge cases.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class NavigationGraphScoutPlanTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        texts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 205, tapY: startY + Double(i) * 80, confidence: 0.95)
        }
    }

    private func noIcons() -> [IconDetector.DetectedIcon] { [] }

    // MARK: - Root and Unvisited Accessors

    func testRootScreenType() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Home", "Search", "Profile"]),
            icons: noIcons(), hints: [], screenshot: "img", screenType: .tabRoot
        )

        XCTAssertEqual(graph.rootScreenType(), .tabRoot)
    }

    func testHasUnvisitedElements() {
        let graph = NavigationGraph()
        let elements = makeElements(["Settings", "General"])
        graph.start(
            rootElements: elements, icons: noIcons(), hints: [],
            screenshot: "img", screenType: .settings
        )
        let fp = graph.currentFingerprint

        XCTAssertTrue(graph.hasUnvisitedElements(for: fp))

        graph.markElementVisited(fingerprint: fp, elementText: "Settings")
        XCTAssertTrue(graph.hasUnvisitedElements(for: fp), "Still has General")

        graph.markElementVisited(fingerprint: fp, elementText: "General")
        XCTAssertFalse(graph.hasUnvisitedElements(for: fp), "All visited")
    }

    func testRootFingerprint() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]), icons: noIcons(),
            hints: [], screenshot: "img", screenType: .settings
        )
        let rootFP = graph.rootFingerprint

        // Navigate away
        _ = graph.recordTransition(
            elements: makeElements(["About"]), icons: noIcons(), hints: [],
            screenshot: "img2", actionType: "tap", elementText: "Settings",
            screenType: .detail
        )

        // Root fingerprint should remain unchanged
        XCTAssertEqual(graph.rootFingerprint, rootFP)
        XCTAssertNotEqual(graph.currentFingerprint, rootFP)
    }

    // MARK: - Backtrack Fingerprint Sync

    func testSetCurrentFingerprintUpdatesGraph() {
        let graph = NavigationGraph()
        let rootElements = makeElements(["Settings", "General"])
        graph.start(
            rootElements: rootElements, icons: noIcons(), hints: [],
            screenshot: "img", screenType: .settings
        )
        let rootFP = graph.currentFingerprint

        // Navigate to a child screen
        _ = graph.recordTransition(
            elements: makeElements(["About", "Version"]), icons: noIcons(),
            hints: [], screenshot: "img2", actionType: "tap",
            elementText: "General", screenType: .detail
        )
        let childFP = graph.currentFingerprint
        XCTAssertNotEqual(childFP, rootFP, "Should be on child screen")

        // Simulate backtrack by setting fingerprint back to root
        graph.setCurrentFingerprint(rootFP)
        XCTAssertEqual(graph.currentFingerprint, rootFP,
            "setCurrentFingerprint should update to root")
    }

    func testSetCurrentFingerprintAllowsResumingExploration() {
        let graph = NavigationGraph()
        let rootElements = makeElements(["Settings", "General", "Privacy"])
        graph.start(
            rootElements: rootElements, icons: noIcons(), hints: [],
            screenshot: "img", screenType: .settings
        )
        let rootFP = graph.currentFingerprint

        // Navigate to child, mark General as visited
        graph.markElementVisited(fingerprint: rootFP, elementText: "General")
        _ = graph.recordTransition(
            elements: makeElements(["About"]), icons: noIcons(),
            hints: [], screenshot: "img2", actionType: "tap",
            elementText: "General", screenType: .detail
        )

        // Simulate backtrack
        graph.setCurrentFingerprint(rootFP)

        // Root should still have unvisited elements (Privacy, Settings)
        let unvisited = graph.unvisitedElements(for: rootFP)
        XCTAssertTrue(unvisited.contains { $0.text == "Privacy" },
            "Privacy should be unvisited on root after backtrack")
        XCTAssertTrue(unvisited.contains { $0.text == "Settings" },
            "Settings should be unvisited on root after backtrack")
    }

    // MARK: - Scout Phase Support

    func testScoutResultRecordAndRetrieval() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings", "General"]), icons: noIcons(),
            hints: [], screenshot: "img", screenType: .settings
        )
        let fp = graph.currentFingerprint

        graph.recordScoutResult(fingerprint: fp, elementText: "General", result: .navigated)
        graph.recordScoutResult(fingerprint: fp, elementText: "Settings", result: .noChange)

        let results = graph.scoutResults(for: fp)
        XCTAssertEqual(results["General"], .navigated)
        XCTAssertEqual(results["Settings"], .noChange)
    }

    func testTraversalPhaseDefaultsToScout() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]), icons: noIcons(),
            hints: [], screenshot: "img", screenType: .settings
        )

        XCTAssertEqual(graph.traversalPhase(for: graph.currentFingerprint), .scout)
    }

    func testSetTraversalPhase() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]), icons: noIcons(),
            hints: [], screenshot: "img", screenType: .settings
        )
        let fp = graph.currentFingerprint

        graph.setTraversalPhase(for: fp, phase: .dive)
        XCTAssertEqual(graph.traversalPhase(for: fp), .dive)

        graph.setTraversalPhase(for: fp, phase: .exhausted)
        XCTAssertEqual(graph.traversalPhase(for: fp), .exhausted)
    }

    func testScoutResultsIndependentPerScreen() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings", "General"]), icons: noIcons(),
            hints: [], screenshot: "img0", screenType: .settings
        )
        let rootFP = graph.currentFingerprint

        // Navigate to a new screen
        _ = graph.recordTransition(
            elements: makeElements(["About", "Version"]),
            icons: noIcons(), hints: [], screenshot: "img1",
            actionType: "tap", elementText: "General", screenType: .detail
        )
        let childFP = graph.currentFingerprint

        // Record scout results on different screens
        graph.recordScoutResult(fingerprint: rootFP, elementText: "General", result: .navigated)
        graph.recordScoutResult(fingerprint: childFP, elementText: "About", result: .noChange)

        // Verify independence
        let rootResults = graph.scoutResults(for: rootFP)
        let childResults = graph.scoutResults(for: childFP)
        XCTAssertEqual(rootResults.count, 1)
        XCTAssertEqual(childResults.count, 1)
        XCTAssertEqual(rootResults["General"], .navigated)
        XCTAssertEqual(childResults["About"], .noChange)
    }

    func testScoutDataClearedOnRestart() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]), icons: noIcons(),
            hints: [], screenshot: "img", screenType: .settings
        )
        let fp = graph.currentFingerprint

        graph.recordScoutResult(fingerprint: fp, elementText: "Settings", result: .navigated)
        graph.setTraversalPhase(for: fp, phase: .dive)

        // Restart graph
        graph.start(
            rootElements: makeElements(["Photos"]), icons: noIcons(),
            hints: [], screenshot: "img2", screenType: .tabRoot
        )
        let newFP = graph.currentFingerprint

        // Scout data from previous session should be cleared
        XCTAssertTrue(graph.scoutResults(for: fp).isEmpty)
        XCTAssertEqual(graph.traversalPhase(for: newFP), .scout)
    }

    // MARK: - Screen Plan Support

    func testSetAndGetScreenPlan() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings", "General"]), icons: noIcons(),
            hints: [], screenshot: "img", screenType: .settings
        )
        let fp = graph.currentFingerprint

        let plan = [
            RankedElement(
                point: TapPoint(text: "General", tapX: 100, tapY: 400, confidence: 0.9),
                score: 5.0, reason: "chevron +3, short +2"
            ),
        ]

        XCTAssertNil(graph.screenPlan(for: fp), "No plan before setting")

        graph.setScreenPlan(for: fp, plan: plan)

        let retrieved = graph.screenPlan(for: fp)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.count, 1)
        XCTAssertEqual(retrieved?.first?.point.text, "General")
    }

    func testNextPlannedElementSkipsVisited() {
        let graph = NavigationGraph()
        let elements = makeElements(["General", "Privacy", "About"])
        graph.start(
            rootElements: elements, icons: noIcons(),
            hints: [], screenshot: "img", screenType: .settings
        )
        let fp = graph.currentFingerprint

        let plan = [
            RankedElement(
                point: TapPoint(text: "General", tapX: 205, tapY: 120, confidence: 0.9),
                score: 5.0, reason: "top"
            ),
            RankedElement(
                point: TapPoint(text: "Privacy", tapX: 205, tapY: 200, confidence: 0.9),
                score: 3.0, reason: "mid"
            ),
            RankedElement(
                point: TapPoint(text: "About", tapX: 205, tapY: 280, confidence: 0.9),
                score: 1.0, reason: "low"
            ),
        ]
        graph.setScreenPlan(for: fp, plan: plan)

        // First call should return highest scored
        let first = graph.nextPlannedElement(for: fp)
        XCTAssertEqual(first?.point.text, "General")

        // Mark General as visited
        graph.markElementVisited(fingerprint: fp, elementText: "General")
        let second = graph.nextPlannedElement(for: fp)
        XCTAssertEqual(second?.point.text, "Privacy",
            "Should skip visited General, return Privacy")

        // Mark Privacy as visited
        graph.markElementVisited(fingerprint: fp, elementText: "Privacy")
        let third = graph.nextPlannedElement(for: fp)
        XCTAssertEqual(third?.point.text, "About")

        // Mark all visited
        graph.markElementVisited(fingerprint: fp, elementText: "About")
        let none = graph.nextPlannedElement(for: fp)
        XCTAssertNil(none, "All visited should return nil")
    }

    func testClearScreenPlan() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]), icons: noIcons(),
            hints: [], screenshot: "img", screenType: .settings
        )
        let fp = graph.currentFingerprint

        let plan = [
            RankedElement(
                point: TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.9),
                score: 1.0, reason: "test"
            ),
        ]
        graph.setScreenPlan(for: fp, plan: plan)
        XCTAssertNotNil(graph.screenPlan(for: fp))

        graph.clearScreenPlan(for: fp)
        XCTAssertNil(graph.screenPlan(for: fp),
            "Plan should be nil after clearing")
    }

    func testScreenPlanClearedOnStart() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]), icons: noIcons(),
            hints: [], screenshot: "img", screenType: .settings
        )
        let fp = graph.currentFingerprint

        let plan = [
            RankedElement(
                point: TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.9),
                score: 1.0, reason: "test"
            ),
        ]
        graph.setScreenPlan(for: fp, plan: plan)

        // Restart graph
        graph.start(
            rootElements: makeElements(["Photos"]), icons: noIcons(),
            hints: [], screenshot: "img2", screenType: .tabRoot
        )

        XCTAssertNil(graph.screenPlan(for: fp),
            "Plans from previous session should be cleared on start")
    }

    // MARK: - Edge Cases

    func testDuplicateDoesNotAddEdge() {
        let graph = NavigationGraph()
        let elements = makeElements(["Settings", "General"])
        graph.start(
            rootElements: elements, icons: noIcons(), hints: [],
            screenshot: "img", screenType: .settings
        )

        let result = graph.recordTransition(
            elements: elements, icons: noIcons(), hints: [],
            screenshot: "img2", actionType: "tap",
            elementText: "General", screenType: .settings
        )

        XCTAssertEqual(graph.edgeCount, 0,
            "Duplicate transitions should not create edges")
        if case .duplicate = result {} else {
            XCTFail("Expected .duplicate")
        }
    }

    // MARK: - Global Component Tracking (breadth_navigation)

    func testRegisterBreadthLabelsAndQuery() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Résumé", "Partage"]),
            icons: noIcons(), hints: [], screenshot: "img", screenType: .tabRoot
        )

        XCTAssertFalse(graph.isBreadthLabel("Résumé"))

        graph.registerBreadthLabels(["Résumé", "Partage", "Parcourir"])
        XCTAssertTrue(graph.isBreadthLabel("Résumé"))
        XCTAssertTrue(graph.isBreadthLabel("Partage"))
        XCTAssertTrue(graph.isBreadthLabel("Parcourir"))
        XCTAssertFalse(graph.isBreadthLabel("Activité"))
    }

    func testGlobalVisitedSkipsPlannedElement() {
        let graph = NavigationGraph()
        let elements = makeElements(["Résumé", "Activité", "Partage"])
        graph.start(
            rootElements: elements, icons: noIcons(), hints: [],
            screenshot: "img", screenType: .tabRoot
        )
        let fp = graph.currentFingerprint

        // Build a plan with 3 items
        let plan = elements.enumerated().map { (i, el) in
            RankedElement(
                point: el, score: Double(10 - i),
                reason: "test", displayLabel: el.text
            )
        }
        graph.setScreenPlan(for: fp, plan: plan)

        // First planned element is "Résumé" (highest score)
        XCTAssertEqual(graph.nextPlannedElement(for: fp)?.displayLabel, "Résumé")

        // Mark "Résumé" as globally visited (simulating breadth navigation tap)
        graph.markGloballyVisited(label: "Résumé")

        // Next planned should skip "Résumé" → return "Activité"
        XCTAssertEqual(graph.nextPlannedElement(for: fp)?.displayLabel, "Activité")
    }

    func testGlobalVisitedAffectsAllScreens() {
        let graph = NavigationGraph()
        let rootElements = makeElements(["Résumé", "Activité"])
        graph.start(
            rootElements: rootElements, icons: noIcons(), hints: [],
            screenshot: "img", screenType: .tabRoot
        )
        let rootFP = graph.currentFingerprint

        // Navigate to a child screen with overlapping tab items
        let childElements = makeElements(["Détails", "Résumé", "Activité"], startY: 200)
        _ = graph.recordTransition(
            elements: childElements, icons: noIcons(), hints: [],
            screenshot: "img2", actionType: "tap",
            elementText: "Détails", screenType: .detail
        )
        let childFP = graph.currentFingerprint

        // Build plans for both screens
        let rootPlan = rootElements.map {
            RankedElement(point: $0, score: 5, reason: "test", displayLabel: $0.text)
        }
        let childPlan = childElements.map {
            RankedElement(point: $0, score: 5, reason: "test", displayLabel: $0.text)
        }
        graph.setScreenPlan(for: rootFP, plan: rootPlan)
        graph.setScreenPlan(for: childFP, plan: childPlan)

        // Mark "Résumé" globally visited from root screen
        graph.markGloballyVisited(label: "Résumé")

        // On child screen, "Résumé" should be skipped too → first result is "Détails"
        XCTAssertEqual(graph.nextPlannedElement(for: childFP)?.displayLabel, "Détails")
    }

    func testStartResetsGlobalTracking() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["A"]),
            icons: noIcons(), hints: [], screenshot: "img", screenType: .tabRoot
        )

        graph.registerBreadthLabels(["TabItem"])
        graph.markGloballyVisited(label: "TabItem")
        XCTAssertTrue(graph.isBreadthLabel("TabItem"))

        // Re-start should clear all global tracking
        graph.start(
            rootElements: makeElements(["B"]),
            icons: noIcons(), hints: [], screenshot: "img2", screenType: .tabRoot
        )
        XCTAssertFalse(graph.isBreadthLabel("TabItem"))
    }
}
