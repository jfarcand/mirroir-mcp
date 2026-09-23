// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for NavigationGraph: lifecycle, transitions, visited elements, and snapshot export.
// ABOUTME: Verifies thread-safe graph accumulation, visited element tracking, and edge recording.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class NavigationGraphTests: XCTestCase {

    // MARK: - Test Helpers

    func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        texts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 205, tapY: startY + Double(i) * 80, confidence: 0.95)
        }
    }

    func noIcons() -> [IconDetector.DetectedIcon] { [] }

    // MARK: - Lifecycle

    func testStartInitializesGraph() {
        let graph = NavigationGraph()

        XCTAssertFalse(graph.started)
        XCTAssertEqual(graph.nodeCount, 0)

        let elements = makeElements(["Settings", "General", "Privacy"])
        graph.start(
            rootElements: elements, icons: noIcons(), hints: [],
            screenshot: "base64img", screenType: .settings
        )

        XCTAssertTrue(graph.started)
        XCTAssertEqual(graph.nodeCount, 1)
        XCTAssertEqual(graph.edgeCount, 0)
        XCTAssertFalse(graph.currentFingerprint.isEmpty)
    }

    func testStartResetsExistingGraph() {
        let graph = NavigationGraph()

        graph.start(
            rootElements: makeElements(["Settings"]), icons: noIcons(), hints: [],
            screenshot: "img1", screenType: .settings
        )
        let firstFP = graph.currentFingerprint

        // Record a transition to add a second node
        _ = graph.recordTransition(
            elements: makeElements(["About", "Version"]),
            icons: noIcons(), hints: [], screenshot: "img2",
            actionType: "tap", elementText: "About", screenType: .detail
        )
        XCTAssertEqual(graph.nodeCount, 2)

        // Restart should reset
        graph.start(
            rootElements: makeElements(["Photos", "Albums"]), icons: noIcons(), hints: [],
            screenshot: "img3", screenType: .tabRoot
        )

        XCTAssertEqual(graph.nodeCount, 1)
        XCTAssertEqual(graph.edgeCount, 0)
        XCTAssertNotEqual(graph.currentFingerprint, firstFP)
    }

    // MARK: - Transitions

    func testRecordTransitionNewScreen() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings", "General"]), icons: noIcons(),
            hints: [], screenshot: "img1", screenType: .settings
        )
        let rootFP = graph.currentFingerprint

        let result = graph.recordTransition(
            elements: makeElements(["About", "Name", "iOS Version"]),
            icons: noIcons(), hints: [], screenshot: "img2",
            actionType: "tap", elementText: "General", screenType: .detail
        )

        if case .newScreen(let fp) = result {
            XCTAssertFalse(fp.isEmpty)
            XCTAssertNotEqual(fp, rootFP)
        } else {
            XCTFail("Expected .newScreen, got \(result)")
        }

        XCTAssertEqual(graph.nodeCount, 2)
        XCTAssertEqual(graph.edgeCount, 1)
    }

    func testRecordTransitionDuplicate() {
        let graph = NavigationGraph()
        let elements = makeElements(["Settings", "General", "Privacy"])
        graph.start(
            rootElements: elements, icons: noIcons(), hints: [],
            screenshot: "img1", screenType: .settings
        )

        // Tapping something that doesn't change the screen
        let result = graph.recordTransition(
            elements: elements, icons: noIcons(), hints: [],
            screenshot: "img2", actionType: "tap",
            elementText: "Privacy", screenType: .settings
        )

        if case .duplicate = result {
            // Expected
        } else {
            XCTFail("Expected .duplicate, got \(result)")
        }

        XCTAssertEqual(graph.nodeCount, 1, "No new node for duplicate")
        XCTAssertEqual(graph.edgeCount, 0, "No edge for duplicate")
    }

    func testRecordTransitionRevisited() {
        let graph = NavigationGraph()
        let rootElements = makeElements(["Settings", "General"])
        graph.start(
            rootElements: rootElements, icons: noIcons(), hints: [],
            screenshot: "img1", screenType: .settings
        )
        let rootFP = graph.currentFingerprint

        // Navigate away
        _ = graph.recordTransition(
            elements: makeElements(["About", "Name", "Version"]),
            icons: noIcons(), hints: [], screenshot: "img2",
            actionType: "tap", elementText: "General", screenType: .detail
        )
        XCTAssertEqual(graph.nodeCount, 2)

        // Navigate back to root (same structural elements)
        let result = graph.recordTransition(
            elements: rootElements, icons: noIcons(), hints: [],
            screenshot: "img3", actionType: "press_key",
            elementText: "[", screenType: .settings
        )

        if case .revisited(let fp) = result {
            XCTAssertEqual(fp, rootFP,
                "Should recognize root screen by similarity")
        } else {
            XCTFail("Expected .revisited, got \(result)")
        }

        XCTAssertEqual(graph.nodeCount, 2, "No new node when revisiting")
        XCTAssertEqual(graph.edgeCount, 2, "Both edges should be recorded")
    }

    func testMultipleTransitionsChain() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings", "General"]),
            icons: noIcons(), hints: [], screenshot: "img0", screenType: .settings
        )

        let result1 = graph.recordTransition(
            elements: makeElements(["About", "Name"]),
            icons: noIcons(), hints: [], screenshot: "img1",
            actionType: "tap", elementText: "General", screenType: .list
        )

        let result2 = graph.recordTransition(
            elements: makeElements(["Version", "Build Number"]),
            icons: noIcons(), hints: [], screenshot: "img2",
            actionType: "tap", elementText: "About", screenType: .detail
        )

        if case .newScreen = result1 {} else { XCTFail("Expected .newScreen for result1") }
        if case .newScreen = result2 {} else { XCTFail("Expected .newScreen for result2") }

        XCTAssertEqual(graph.nodeCount, 3)
        XCTAssertEqual(graph.edgeCount, 2)
    }

    // MARK: - Visited Elements

    func testMarkElementVisited() {
        let graph = NavigationGraph()
        let elements = makeElements(["Settings", "General", "Privacy", "About"])
        graph.start(
            rootElements: elements, icons: noIcons(), hints: [],
            screenshot: "img1", screenType: .settings
        )
        let fp = graph.currentFingerprint

        // All elements should be unvisited initially
        let unvisited1 = graph.unvisitedElements(for: fp)
        XCTAssertEqual(unvisited1.count, 4)

        // Mark "General" as visited
        graph.markElementVisited(fingerprint: fp, elementText: "General")

        let unvisited2 = graph.unvisitedElements(for: fp)
        XCTAssertEqual(unvisited2.count, 3)
        XCTAssertFalse(unvisited2.contains(where: { $0.text == "General" }))
    }

    func testUnvisitedElementsForUnknownFingerprint() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]), icons: noIcons(),
            hints: [], screenshot: "img", screenType: .settings
        )

        let result = graph.unvisitedElements(for: "nonexistent")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Node Access

    func testNodeForFingerprint() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]), icons: noIcons(),
            hints: ["Back button detected"], screenshot: "img1",
            screenType: .settings
        )
        let fp = graph.currentFingerprint

        let node = graph.node(for: fp)
        XCTAssertNotNil(node)
        XCTAssertEqual(node?.depth, 0)
        XCTAssertEqual(node?.screenType, .settings)
        XCTAssertEqual(node?.hints, ["Back button detected"])
        XCTAssertEqual(node?.screenshotBase64, "img1")
    }

    func testNodeDepthIncrementsOnNavigation() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]), icons: noIcons(),
            hints: [], screenshot: "img0", screenType: .settings
        )

        _ = graph.recordTransition(
            elements: makeElements(["About", "Version"]),
            icons: noIcons(), hints: [], screenshot: "img1",
            actionType: "tap", elementText: "Settings",
            screenType: .detail
        )

        let fp = graph.currentFingerprint
        let node = graph.node(for: fp)
        XCTAssertEqual(node?.depth, 1)
    }

    // MARK: - Snapshot

    func testFinalizeProducesSnapshot() {
        let graph = NavigationGraph()
        let rootElements = makeElements(["Settings", "General"])
        graph.start(
            rootElements: rootElements, icons: noIcons(), hints: [],
            screenshot: "img0", screenType: .settings
        )

        _ = graph.recordTransition(
            elements: makeElements(["About", "Version"]),
            icons: noIcons(), hints: [], screenshot: "img1",
            actionType: "tap", elementText: "General", screenType: .detail
        )

        let snapshot = graph.finalize()

        XCTAssertEqual(snapshot.nodes.count, 2)
        XCTAssertEqual(snapshot.edges.count, 1)
        XCTAssertFalse(snapshot.rootFingerprint.isEmpty)
        XCTAssertTrue(snapshot.nodes.keys.contains(snapshot.rootFingerprint))
    }

    func testSnapshotEdgesHaveCorrectStructure() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]), icons: noIcons(),
            hints: [], screenshot: "img0", screenType: .settings
        )
        let rootFP = graph.currentFingerprint

        _ = graph.recordTransition(
            elements: makeElements(["About", "Version"]),
            icons: noIcons(), hints: [], screenshot: "img1",
            actionType: "tap", elementText: "Settings", screenType: .detail
        )

        let snapshot = graph.finalize()
        let edge = snapshot.edges[0]

        XCTAssertEqual(edge.fromFingerprint, rootFP)
        XCTAssertEqual(edge.actionType, "tap")
        XCTAssertEqual(edge.elementText, "Settings")
        XCTAssertTrue(snapshot.nodes.keys.contains(edge.toFingerprint))
    }

}
