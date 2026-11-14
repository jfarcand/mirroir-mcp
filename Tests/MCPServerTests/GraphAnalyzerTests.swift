/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Unit tests for GraphAnalyzer: Tarjan SCC detection, condensation DAG, and room summary.
// ABOUTME: Verifies correct SCC grouping for linear, cyclic, and multi-component graphs.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class GraphAnalyzerTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        texts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 205, tapY: startY + Double(i) * 80, confidence: 0.95)
        }
    }

    /// Build a graph with a cycle: root -> A -> B -> root
    private func buildCyclicGraph() -> GraphSnapshot {
        let graph = NavigationGraph()
        let rootElements = makeElements(["Home", "Tab1", "Tab2", "Tab3", "Tab4"])
        graph.start(
            rootElements: rootElements, icons: [], hints: [],
            screenshot: "root_img", screenType: .tabRoot
        )

        // root -> A
        _ = graph.recordTransition(
            elements: makeElements(["Page A", "Item 1", "Item 2", "Item 3"]),
            icons: [], hints: [], screenshot: "a_img",
            actionType: "tap", elementText: "Tab1", screenType: .list
        )
        let fpA = graph.currentFingerprint

        // A -> B
        _ = graph.recordTransition(
            elements: makeElements(["Page B", "Detail 1", "Detail 2"]),
            icons: [], hints: [], screenshot: "b_img",
            actionType: "tap", elementText: "Item 1", screenType: .detail
        )

        // B -> root (revisit creates the cycle edge)
        _ = graph.recordTransition(
            elements: rootElements, icons: [], hints: [],
            screenshot: "root_img2", actionType: "tap",
            elementText: "Detail 1", screenType: .tabRoot
        )

        return graph.finalize()
    }

    /// Build a linear graph: root -> A -> B (no cycles)
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

    // MARK: - SCC Detection

    func testEmptyGraphHasNoSCCs() {
        let snapshot = GraphSnapshot(
            nodes: [:], edges: [], adjacency: [:],
            rootFingerprint: "", deadEdges: [], recoveryEvents: []
        )

        let sccs = GraphAnalyzer.computeSCCs(snapshot: snapshot)

        XCTAssertTrue(sccs.isEmpty)
    }

    func testLinearGraphHasSingletonSCCs() {
        let snapshot = buildLinearGraph()

        let sccs = GraphAnalyzer.computeSCCs(snapshot: snapshot)

        XCTAssertEqual(sccs.count, 3,
            "Linear graph with 3 nodes should produce 3 singleton SCCs")
        for scc in sccs {
            XCTAssertEqual(scc.count, 1,
                "Each SCC in a linear graph should contain exactly one screen")
        }
    }

    func testCyclicGraphDetectsCycle() {
        let snapshot = buildCyclicGraph()

        let sccs = GraphAnalyzer.computeSCCs(snapshot: snapshot)

        // The cycle root -> A -> B -> root means all three should be in one SCC
        let largeSCCs = sccs.filter { $0.count > 1 }
        XCTAssertEqual(largeSCCs.count, 1,
            "Cyclic graph should have exactly one non-singleton SCC")
        XCTAssertEqual(largeSCCs.first?.count, 3,
            "The cycle SCC should contain all 3 screens")
    }

    func testSCCsContainAllNodes() {
        let snapshot = buildLinearGraph()

        let sccs = GraphAnalyzer.computeSCCs(snapshot: snapshot)
        let allFPs = Set(sccs.flatMap { $0 })

        XCTAssertEqual(allFPs.count, snapshot.nodes.count,
            "SCCs should cover every node in the graph")
        for fp in snapshot.nodes.keys {
            XCTAssertTrue(allFPs.contains(fp),
                "Every graph node should appear in exactly one SCC")
        }
    }

    func testSingleNodeGraphHasOneSCC() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Home"]), icons: [], hints: [],
            screenshot: "img", screenType: .tabRoot
        )
        let snapshot = graph.finalize()

        let sccs = GraphAnalyzer.computeSCCs(snapshot: snapshot)

        XCTAssertEqual(sccs.count, 1)
        XCTAssertEqual(sccs.first?.count, 1)
    }

    // MARK: - Condensation DAG

    func testCondensationDAGLinearGraph() {
        let snapshot = buildLinearGraph()
        let sccs = GraphAnalyzer.computeSCCs(snapshot: snapshot)

        let dag = GraphAnalyzer.condense(snapshot: snapshot, sccs: sccs)

        XCTAssertEqual(dag.nodes.count, 3,
            "Linear graph condensation should have 3 nodes (one per singleton SCC)")
        XCTAssertEqual(dag.edges.count, 2,
            "Linear graph condensation should have 2 edges")
    }

    func testCondensationDAGCyclicGraph() {
        let snapshot = buildCyclicGraph()
        let sccs = GraphAnalyzer.computeSCCs(snapshot: snapshot)

        let dag = GraphAnalyzer.condense(snapshot: snapshot, sccs: sccs)

        // All 3 nodes are in one SCC, so DAG should have 1 node and 0 edges
        XCTAssertEqual(dag.nodes.count, 1,
            "Fully cyclic graph condensation should have 1 node")
        XCTAssertEqual(dag.edges.count, 0,
            "Single-SCC condensation should have no edges")
    }

    func testCondensationNodeIndicesMatchArray() {
        let snapshot = buildLinearGraph()
        let sccs = GraphAnalyzer.computeSCCs(snapshot: snapshot)
        let dag = GraphAnalyzer.condense(snapshot: snapshot, sccs: sccs)

        for (i, node) in dag.nodes.enumerated() {
            XCTAssertEqual(node.index, i,
                "SCCNode index should match its position in the nodes array")
        }
    }

    func testCondensationEdgesReferenceValidIndices() {
        let snapshot = buildLinearGraph()
        let sccs = GraphAnalyzer.computeSCCs(snapshot: snapshot)
        let dag = GraphAnalyzer.condense(snapshot: snapshot, sccs: sccs)

        for edge in dag.edges {
            XCTAssertTrue(edge.from >= 0 && edge.from < dag.nodes.count,
                "Edge 'from' index should be valid")
            XCTAssertTrue(edge.to >= 0 && edge.to < dag.nodes.count,
                "Edge 'to' index should be valid")
            XCTAssertNotEqual(edge.from, edge.to,
                "Condensation DAG should have no self-loops")
        }
    }

    // MARK: - Room Summary

    func testRoomSummaryLinearGraph() {
        let snapshot = buildLinearGraph()

        let summary = GraphAnalyzer.roomSummary(snapshot: snapshot)

        XCTAssertTrue(summary.contains("3 rooms"),
            "Linear graph should report 3 rooms. Got: \(summary)")
        XCTAssertTrue(summary.contains("1 screen"),
            "Each room should have 1 screen. Got: \(summary)")
    }

    func testRoomSummaryCyclicGraph() {
        let snapshot = buildCyclicGraph()

        let summary = GraphAnalyzer.roomSummary(snapshot: snapshot)

        XCTAssertTrue(summary.contains("1 room"),
            "Fully cyclic graph should report 1 room. Got: \(summary)")
        XCTAssertTrue(summary.contains("3 screens"),
            "The single room should have 3 screens. Got: \(summary)")
    }

    func testRoomSummaryEmptyGraph() {
        let snapshot = GraphSnapshot(
            nodes: [:], edges: [], adjacency: [:],
            rootFingerprint: "", deadEdges: [], recoveryEvents: []
        )

        let summary = GraphAnalyzer.roomSummary(snapshot: snapshot)

        XCTAssertEqual(summary, "0 rooms")
    }

    func testRoomSummaryUsesNavBarTitle() {
        let graph = NavigationGraph()
        // Place "Settings" in header zone (Y=150) so it's extracted as nav bar title
        let rootElements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 150, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        graph.start(
            rootElements: rootElements, icons: [], hints: [],
            screenshot: "img", screenType: .settings
        )
        let snapshot = graph.finalize()

        let summary = GraphAnalyzer.roomSummary(snapshot: snapshot)

        XCTAssertTrue(summary.contains("Settings"),
            "Room summary should use nav bar title. Got: \(summary)")
    }

    // MARK: - Exploration Status

    func testCondensationTracksExplorationStatus() {
        let graph = NavigationGraph()
        let elements = makeElements(["A", "B", "C"])
        graph.start(
            rootElements: elements, icons: [], hints: [],
            screenshot: "img", screenType: .settings
        )
        let fp = graph.currentFingerprint

        // Mark all elements as visited
        graph.markElementVisited(fingerprint: fp, elementText: "A")
        graph.markElementVisited(fingerprint: fp, elementText: "B")
        graph.markElementVisited(fingerprint: fp, elementText: "C")

        let snapshot = graph.finalize()
        let sccs = GraphAnalyzer.computeSCCs(snapshot: snapshot)
        let dag = GraphAnalyzer.condense(snapshot: snapshot, sccs: sccs)

        XCTAssertEqual(dag.nodes.count, 1)
        XCTAssertTrue(dag.nodes[0].isFullyExplored,
            "SCC should be fully explored when all elements in all screens are visited")
    }

    func testCondensationPartiallyExplored() {
        let graph = NavigationGraph()
        let elements = makeElements(["A", "B", "C"])
        graph.start(
            rootElements: elements, icons: [], hints: [],
            screenshot: "img", screenType: .settings
        )
        let fp = graph.currentFingerprint

        // Mark only some elements as visited
        graph.markElementVisited(fingerprint: fp, elementText: "A")

        let snapshot = graph.finalize()
        let sccs = GraphAnalyzer.computeSCCs(snapshot: snapshot)
        let dag = GraphAnalyzer.condense(snapshot: snapshot, sccs: sccs)

        XCTAssertFalse(dag.nodes[0].isFullyExplored,
            "SCC should not be fully explored when some elements are unvisited")
    }
}
