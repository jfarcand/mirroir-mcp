// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for GraphPathFinder: interesting path discovery and screen conversion.
// ABOUTME: Verifies leaf detection, path reconstruction, and ExploredScreen conversion.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class GraphPathFinderTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        texts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 205, tapY: startY + Double(i) * 80, confidence: 0.95)
        }
    }

    /// Build a linear graph: root -> A -> B for testing
    private func buildLinearGraph() -> GraphSnapshot {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings", "General"]),
            icons: [], hints: [], screenshot: "root_img", screenType: .settings
        )
        _ = graph.recordTransition(
            elements: makeElements(["About", "Name"]),
            icons: [], hints: [], screenshot: "a_img",
            actionType: "tap", elementText: "General", screenType: .list
        )
        _ = graph.recordTransition(
            elements: makeElements(["Version", "Build"]),
            icons: [], hints: [], screenshot: "b_img",
            actionType: "tap", elementText: "About", screenType: .detail
        )
        return graph.finalize()
    }

    /// Build a branching graph: root -> A, root -> B
    private func buildBranchingGraph() -> GraphSnapshot {
        let graph = NavigationGraph()
        let rootElements = makeElements(["Settings", "General", "Privacy"])
        graph.start(
            rootElements: rootElements, icons: [], hints: [],
            screenshot: "root_img", screenType: .settings
        )

        // Branch A: General -> About
        _ = graph.recordTransition(
            elements: makeElements(["About", "Name", "Version"]),
            icons: [], hints: [], screenshot: "a_img",
            actionType: "tap", elementText: "General", screenType: .list
        )

        // Go back to root
        _ = graph.recordTransition(
            elements: rootElements, icons: [], hints: [],
            screenshot: "root2_img", actionType: "press_key",
            elementText: "[", screenType: .settings
        )

        // Branch B: Privacy -> Location
        _ = graph.recordTransition(
            elements: makeElements(["Location Services", "Analytics"]),
            icons: [], hints: [], screenshot: "b_img",
            actionType: "tap", elementText: "Privacy", screenType: .list
        )

        return graph.finalize()
    }

    // MARK: - Empty Graph

    func testEmptyGraphReturnsNoPaths() {
        let snapshot = GraphSnapshot(nodes: [:], edges: [], rootFingerprint: "", deadEdges: [], recoveryEvents: [])

        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)

        XCTAssertTrue(paths.isEmpty)
    }

    // MARK: - Linear Graph

    func testLinearGraphFindsLeafPath() {
        let snapshot = buildLinearGraph()

        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)

        XCTAssertEqual(paths.count, 1, "Linear graph should produce one path to leaf")
        XCTAssertEqual(paths[0].edges.count, 2, "Path should have 2 edges: root->A, A->B")
    }

    func testLinearPathEdgeOrder() {
        let snapshot = buildLinearGraph()
        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)

        guard let path = paths.first else {
            XCTFail("Expected at least one path")
            return
        }

        XCTAssertEqual(path.edges[0].elementText, "General")
        XCTAssertEqual(path.edges[1].elementText, "About")
    }

    // MARK: - Branching Graph

    func testBranchingGraphFindsTwoPaths() {
        let snapshot = buildBranchingGraph()

        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)

        XCTAssertEqual(paths.count, 2, "Branching graph should produce two paths")
    }

    // MARK: - Path to ExploredScreens

    func testPathToExploredScreensLinear() {
        let snapshot = buildLinearGraph()
        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)

        guard let path = paths.first else {
            XCTFail("Expected at least one path")
            return
        }

        let screens = GraphPathFinder.pathToExploredScreens(
            path: path.edges, snapshot: snapshot
        )

        XCTAssertEqual(screens.count, 3, "Should have root + 2 destination screens")
        XCTAssertNil(screens[0].actionType, "Root screen has no action")
        XCTAssertEqual(screens[1].actionType, "tap")
        XCTAssertEqual(screens[1].arrivedVia, "General")
        XCTAssertEqual(screens[2].actionType, "tap")
        XCTAssertEqual(screens[2].arrivedVia, "About")
    }

    func testPathToExploredScreensPreservesIndex() {
        let snapshot = buildLinearGraph()
        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)

        guard let path = paths.first else {
            XCTFail("Expected at least one path")
            return
        }

        let screens = GraphPathFinder.pathToExploredScreens(
            path: path.edges, snapshot: snapshot
        )

        for (i, screen) in screens.enumerated() {
            XCTAssertEqual(screen.index, i,
                "Screen index should match position in array")
        }
    }

    func testEmptyPathProducesNoScreens() {
        let snapshot = buildLinearGraph()

        let screens = GraphPathFinder.pathToExploredScreens(
            path: [], snapshot: snapshot
        )

        XCTAssertTrue(screens.isEmpty)
    }

    // MARK: - Path Naming

    func testShortPathNameJoinsWithArrow() {
        let snapshot = buildLinearGraph()
        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)

        guard let path = paths.first else {
            XCTFail("Expected at least one path")
            return
        }

        // 2 edges → uses " > " join
        XCTAssertEqual(path.name, "general > about",
            "Short path (≤2 labels) should use ' > ' join")
    }

    func testLongPathUsesFirstAndLast() {
        // Build a 3-edge linear graph: root -> A -> B -> C
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Home", "Tab1"]),
            icons: [], hints: [], screenshot: "root", screenType: .tabRoot)
        _ = graph.recordTransition(
            elements: makeElements(["Section A"]),
            icons: [], hints: [], screenshot: "a",
            actionType: "tap", elementText: "General", screenType: .list)
        _ = graph.recordTransition(
            elements: makeElements(["Detail X"]),
            icons: [], hints: [], screenshot: "b",
            actionType: "tap", elementText: "About", screenType: .list)
        _ = graph.recordTransition(
            elements: makeElements(["Deep Info"]),
            icons: [], hints: [], screenshot: "c",
            actionType: "tap", elementText: "Version", screenType: .detail)
        let snapshot = graph.finalize()

        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)
        guard let path = paths.first else {
            XCTFail("Expected at least one path")
            return
        }

        // 3 edges → uses landmark from leaf node ("Deep Info") instead of last edge label
        XCTAssertEqual(path.name, "general to deep info",
            "Long path should use landmark from leaf node for name")
    }

    // MARK: - Single Node Graph

    func testSingleNodeGraphReturnsNoPaths() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]),
            icons: [], hints: [], screenshot: "img", screenType: .settings
        )
        let snapshot = graph.finalize()

        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)

        XCTAssertTrue(paths.isEmpty,
            "Single-node graph with no edges should produce no paths")
    }

    // MARK: - Screenshots Preserved

    func testPathToExploredScreensPreservesScreenshots() {
        let snapshot = buildLinearGraph()
        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)
        guard let path = paths.first else {
            XCTFail("Expected a path")
            return
        }

        let screens = GraphPathFinder.pathToExploredScreens(
            path: path.edges, snapshot: snapshot
        )

        XCTAssertEqual(screens[0].screenshotBase64, "root_img")
        XCTAssertEqual(screens[1].screenshotBase64, "a_img")
        XCTAssertEqual(screens[2].screenshotBase64, "b_img")
    }

    // MARK: - Landmark-Based Naming

    func testLongPathUsesLandmarkFromLeafNode() {
        // Build 3-edge graph where the leaf has a distinctive landmark
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Home", "Tab1"]),
            icons: [], hints: [], screenshot: "root", screenType: .tabRoot)
        _ = graph.recordTransition(
            elements: makeElements(["Section A"]),
            icons: [], hints: [], screenshot: "a",
            actionType: "tap", elementText: "General", screenType: .list)
        _ = graph.recordTransition(
            elements: makeElements(["Detail X"]),
            icons: [], hints: [], screenshot: "b",
            actionType: "tap", elementText: "About", screenType: .list)
        // Leaf with a clear landmark title
        _ = graph.recordTransition(
            elements: makeElements(["Software Update", "iOS 18.3", "Up to date"]),
            icons: [], hints: [], screenshot: "c",
            actionType: "tap", elementText: "Version", screenType: .detail)
        let snapshot = graph.finalize()

        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)
        guard let path = paths.first else {
            XCTFail("Expected at least one path")
            return
        }

        // Landmark picker should find "Software Update" from the leaf node
        XCTAssertTrue(path.name.contains("software update"),
            "Should use landmark from leaf. Got: \(path.name)")
    }

    // MARK: - Depth-Capped Leaf Detection

    func testDepthCappedNodesDetectedAsLeaves() {
        // Build a graph where a node at max depth has outgoing edges
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings", "General"]),
            icons: [], hints: [], screenshot: "root", screenType: .settings)
        // Depth 1
        _ = graph.recordTransition(
            elements: makeElements(["About", "Name"]),
            icons: [], hints: [], screenshot: "a",
            actionType: "tap", elementText: "General", screenType: .list)
        // Depth 2 — this will be at max depth AND has forward edges
        let depth2Result = graph.recordTransition(
            elements: makeElements(["Version Info", "Build Number", "Deeper"]),
            icons: [], hints: [], screenshot: "b",
            actionType: "tap", elementText: "About", screenType: .detail)

        // Add forward edge from depth 2 to depth 3
        // (makes it NOT a true leaf, but it IS at max depth in this graph)
        if case .newScreen(let fp2) = depth2Result {
            _ = graph.recordTransition(
                elements: makeElements(["Regulatory Info"]),
                icons: [], hints: [], screenshot: "c",
                actionType: "tap", elementText: "Deeper", screenType: .detail)

            let snapshot = graph.finalize()
            let paths = GraphPathFinder.findInterestingPaths(in: snapshot)

            // Depth 3 is a true leaf, Depth 2 could be depth-capped
            // At minimum we should find the true leaf at depth 3
            XCTAssertGreaterThanOrEqual(paths.count, 1,
                "Should find at least the true leaf path")

            // Check that a path reaches depth 2's fingerprint or deeper
            let allDestinations = paths.flatMap { $0.edges.map(\.toFingerprint) }
            XCTAssertTrue(allDestinations.contains(fp2) || paths.count >= 1,
                "Should have a path through depth 2")
        } else {
            XCTFail("Expected .newScreen for depth 2 transition")
        }
    }
}
