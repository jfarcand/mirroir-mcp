// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ExplorationSession manifest mode goal queue.
// ABOUTME: Verifies goal handling and NavigationGraph integration.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

extension ExplorationSessionTests {

    // MARK: - Manifest Mode / Goals Queue

    func testManifestFinalizeAdvancesToNextGoal() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "",
            goals: ["check version", "change brightness", "enable dark mode"])

        XCTAssertEqual(session.currentGoal, "check version")
        XCTAssertEqual(session.totalGoals, 3)
        XCTAssertTrue(session.hasMoreGoals)
        XCTAssertEqual(session.remainingGoals, ["change brightness", "enable dark mode"])

        // Capture a screen for goal 1
        session.capture(
            elements: [TapPoint(text: "Version", tapX: 205, tapY: 300, confidence: 0.9)],
            hints: [], actionType: nil, arrivedVia: nil, screenshotBase64: "img1")

        // Finalize goal 1 — should auto-advance
        let data1 = session.finalize()
        XCTAssertNotNil(data1)
        XCTAssertEqual(data1?.goal, "check version")
        XCTAssertTrue(session.active, "Session should still be active with more goals")
        XCTAssertEqual(session.currentGoal, "change brightness")
        XCTAssertEqual(session.screenCount, 0, "Screens should be reset for next goal")
        XCTAssertTrue(session.hasMoreGoals)
        XCTAssertEqual(session.remainingGoals, ["enable dark mode"])

        // Capture for goal 2
        session.capture(
            elements: [TapPoint(text: "Brightness", tapX: 205, tapY: 300, confidence: 0.9)],
            hints: [], actionType: nil, arrivedVia: nil, screenshotBase64: "img2")

        // Finalize goal 2 — still one more
        let data2 = session.finalize()
        XCTAssertNotNil(data2)
        XCTAssertEqual(data2?.goal, "change brightness")
        XCTAssertTrue(session.active)
        XCTAssertEqual(session.currentGoal, "enable dark mode")
        XCTAssertFalse(session.hasMoreGoals)
        XCTAssertTrue(session.remainingGoals.isEmpty)

        // Capture for goal 3
        session.capture(
            elements: [TapPoint(text: "Dark Mode", tapX: 205, tapY: 300, confidence: 0.9)],
            hints: [], actionType: nil, arrivedVia: nil, screenshotBase64: "img3")

        // Finalize goal 3 — session should fully deactivate
        let data3 = session.finalize()
        XCTAssertNotNil(data3)
        XCTAssertEqual(data3?.goal, "enable dark mode")
        XCTAssertFalse(session.active, "Session should be inactive after last goal")
        XCTAssertEqual(session.currentGoal, "")
    }

    func testSingleGoalFinalizeDeactivates() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "check version")

        XCTAssertFalse(session.hasMoreGoals)
        XCTAssertEqual(session.totalGoals, 0)

        session.capture(
            elements: [TapPoint(text: "Version", tapX: 205, tapY: 300, confidence: 0.9)],
            hints: [], actionType: nil, arrivedVia: nil, screenshotBase64: "img")

        let data = session.finalize()
        XCTAssertNotNil(data)
        XCTAssertFalse(session.active, "Single-goal session should deactivate on finalize")
    }

    func testManifestActionLogResetsPerGoal() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "",
            goals: ["goal1", "goal2"])

        session.capture(
            elements: [TapPoint(text: "Screen1", tapX: 205, tapY: 250, confidence: 0.9)],
            hints: [], actionType: nil, arrivedVia: nil, screenshotBase64: "img1")

        XCTAssertEqual(session.actions.count, 1)

        // Finalize goal 1
        _ = session.finalize()

        // Action log should be reset for goal 2
        XCTAssertTrue(session.actions.isEmpty,
            "Action log should reset when advancing to next goal")
    }

    // MARK: - NavigationGraph Integration

    func testGraphPopulatedOnCapture() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "test graph")

        session.capture(
            elements: [TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95)],
            hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img1"
        )

        XCTAssertTrue(session.currentGraph.started,
            "Graph should be started after first capture")
        XCTAssertEqual(session.currentGraph.nodeCount, 1)
    }

    func testGraphRecordsTransitions() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "test graph")

        session.capture(
            elements: [TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95)],
            hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img1"
        )
        session.capture(
            elements: [TapPoint(text: "About", tapX: 205, tapY: 200, confidence: 0.92)],
            hints: [], icons: [],
            actionType: "tap", arrivedVia: "General", screenshotBase64: "img2"
        )

        XCTAssertEqual(session.currentGraph.nodeCount, 2)
        XCTAssertEqual(session.currentGraph.edgeCount, 1)
    }

    func testFinalizeIncludesGraphSnapshot() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "test graph")

        session.capture(
            elements: [TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95)],
            hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img1"
        )
        session.capture(
            elements: [TapPoint(text: "About", tapX: 205, tapY: 200, confidence: 0.92)],
            hints: [], icons: [],
            actionType: "tap", arrivedVia: "General", screenshotBase64: "img2"
        )

        let data = session.finalize()
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.graphSnapshot.nodes.count, 2)
        XCTAssertEqual(data?.graphSnapshot.edges.count, 1)
        XCTAssertFalse(data?.graphSnapshot.rootFingerprint.isEmpty ?? true)
    }

    func testGraphResetsOnManifestGoalAdvance() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "", goals: ["goal1", "goal2"])

        session.capture(
            elements: [TapPoint(text: "Screen1", tapX: 205, tapY: 250, confidence: 0.9)],
            hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img1"
        )

        let data = session.finalize()
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.graphSnapshot.nodes.count, 1)

        // Graph should be reset for next goal
        XCTAssertFalse(session.currentGraph.started,
            "Graph should be reset when advancing to next goal")
    }

    func testGraphWithIcons() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "test icons")

        let icons = [
            IconDetector.DetectedIcon(tapX: 56, tapY: 850, estimatedSize: 24),
            IconDetector.DetectedIcon(tapX: 158, tapY: 850, estimatedSize: 24),
        ]
        session.capture(
            elements: [TapPoint(text: "Home", tapX: 205, tapY: 200, confidence: 0.95)],
            hints: [], icons: icons,
            actionType: nil, arrivedVia: nil, screenshotBase64: "img1"
        )

        let fp = session.currentGraph.currentFingerprint
        let node = session.currentGraph.node(for: fp)
        XCTAssertEqual(node?.icons.count, 2,
            "Icons should be stored in graph node")
    }
}
