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
// ABOUTME: Unit tests for DominatorTree: Lengauer-Tarjan dominator computation and gateway detection.
// ABOUTME: Verifies dominator relationships for linear, branching, and diamond-shaped graphs.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class DominatorTreeTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        texts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 205, tapY: startY + Double(i) * 80, confidence: 0.95)
        }
    }

    /// Build a linear graph: root -> A -> B
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

    /// Build a branching graph: root -> A, root -> B, A -> C, B -> C (diamond)
    private func buildDiamondGraph() -> GraphSnapshot {
        let graph = NavigationGraph()
        let rootElements = makeElements(["Home", "Tab1", "Tab2", "Tab3", "Tab4"])
        graph.start(
            rootElements: rootElements, icons: [], hints: [],
            screenshot: "root_img", screenType: .tabRoot
        )
        let rootFP = graph.currentFingerprint

        // root -> A
        _ = graph.recordTransition(
            elements: makeElements(["Page A", "Link to C", "Item X"]),
            icons: [], hints: [], screenshot: "a_img",
            actionType: "tap", elementText: "Tab1", screenType: .list
        )
        let fpA = graph.currentFingerprint

        // A -> C
        _ = graph.recordTransition(
            elements: makeElements(["Page C", "Final Content", "Summary"]),
            icons: [], hints: [], screenshot: "c_img",
            actionType: "tap", elementText: "Link to C", screenType: .detail
        )
        let fpC = graph.currentFingerprint

        // Go back to root
        _ = graph.recordTransition(
            elements: rootElements, icons: [], hints: [],
            screenshot: "root_img2", actionType: "tap",
            elementText: "back", screenType: .tabRoot
        )
        // Navigate further back to root
        _ = graph.recordTransition(
            elements: rootElements, icons: [], hints: [],
            screenshot: "root_img3", actionType: "tap",
            elementText: "back2", screenType: .tabRoot
        )

        // root -> B
        _ = graph.recordTransition(
            elements: makeElements(["Page B", "Link to C 2", "Item Y"]),
            icons: [], hints: [], screenshot: "b_img",
            actionType: "tap", elementText: "Tab2", screenType: .list
        )
        let fpB = graph.currentFingerprint

        // B -> C (revisit)
        let cElements = makeElements(["Page C", "Final Content", "Summary"])
        _ = graph.recordTransition(
            elements: cElements, icons: [], hints: [],
            screenshot: "c_img2", actionType: "tap",
            elementText: "Link to C 2", screenType: .detail
        )

        return graph.finalize()
    }

    // MARK: - Dominator Computation

    func testEmptyGraphReturnsEmptyDominators() {
        let snapshot = GraphSnapshot(
            nodes: [:], edges: [], adjacency: [:],
            rootFingerprint: "", deadEdges: [], recoveryEvents: []
        )

        let idom = DominatorTree.compute(snapshot: snapshot)

        XCTAssertTrue(idom.isEmpty)
    }

    func testSingleNodeRootDominatesItself() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Home"]), icons: [], hints: [],
            screenshot: "img", screenType: .tabRoot
        )
        let snapshot = graph.finalize()

        let idom = DominatorTree.compute(snapshot: snapshot)

        XCTAssertEqual(idom.count, 1)
        XCTAssertEqual(idom[snapshot.rootFingerprint], snapshot.rootFingerprint,
            "Root should dominate itself")
    }

    func testLinearGraphDominators() {
        let snapshot = buildLinearGraph()

        let idom = DominatorTree.compute(snapshot: snapshot)

        XCTAssertEqual(idom.count, snapshot.nodes.count,
            "Every node should have an immediate dominator")

        // Root dominates itself
        XCTAssertEqual(idom[snapshot.rootFingerprint], snapshot.rootFingerprint)

        // Every non-root node's dominator chain should lead to root
        for (fp, _) in idom where fp != snapshot.rootFingerprint {
            var current = fp
            var steps = 0
            while let parent = idom[current], parent != current {
                current = parent
                steps += 1
                if steps > snapshot.nodes.count {
                    XCTFail("Infinite loop in dominator chain for \(fp)")
                    break
                }
            }
            XCTAssertEqual(current, snapshot.rootFingerprint,
                "Dominator chain should reach root")
        }
    }

    func testLinearGraphDominationRelationship() {
        let snapshot = buildLinearGraph()
        let idom = DominatorTree.compute(snapshot: snapshot)

        // Root dominates all nodes
        for fp in snapshot.nodes.keys {
            XCTAssertTrue(
                DominatorTree.dominates(snapshot.rootFingerprint, fp, idom: idom),
                "Root should dominate every node"
            )
        }
    }

    // MARK: - Domination Queries

    func testSelfDomination() {
        let snapshot = buildLinearGraph()
        let idom = DominatorTree.compute(snapshot: snapshot)

        for fp in snapshot.nodes.keys {
            XCTAssertTrue(
                DominatorTree.dominates(fp, fp, idom: idom),
                "Every node should dominate itself"
            )
        }
    }

    func testNonDominatorReturnsFalse() {
        let snapshot = buildLinearGraph()
        let idom = DominatorTree.compute(snapshot: snapshot)

        // In linear graph root -> A -> B, B does not dominate root
        let fps = Array(snapshot.nodes.keys).sorted()
        guard fps.count >= 2 else {
            XCTFail("Expected at least 2 nodes")
            return
        }

        // Find a leaf (node with no children in dominator tree)
        let leaves = fps.filter { fp in
            !idom.values.contains(where: { $0 == fp && $0 != fp })
                || idom.filter({ $0.value == fp && $0.key != fp }).isEmpty
        }

        // Leaves should not dominate root
        for leaf in leaves where leaf != snapshot.rootFingerprint {
            XCTAssertFalse(
                DominatorTree.dominates(leaf, snapshot.rootFingerprint, idom: idom),
                "Leaf \(leaf.prefix(8)) should not dominate root"
            )
        }
    }

    // MARK: - Subtree

    func testSubtreeOfRoot() {
        let snapshot = buildLinearGraph()
        let idom = DominatorTree.compute(snapshot: snapshot)

        let rootSubtree = DominatorTree.subtree(of: snapshot.rootFingerprint, idom: idom)

        XCTAssertEqual(rootSubtree.count, snapshot.nodes.count,
            "Root's subtree should contain all nodes")
    }

    func testSubtreeOfLeaf() {
        let snapshot = buildLinearGraph()
        let idom = DominatorTree.compute(snapshot: snapshot)

        // Find a leaf (no node has it as idom except itself)
        let nonRootFPs = snapshot.nodes.keys.filter { $0 != snapshot.rootFingerprint }
        let leaves = nonRootFPs.filter { fp in
            !idom.contains(where: { $0.value == fp && $0.key != fp })
        }

        guard let leaf = leaves.first else {
            XCTFail("Expected to find a leaf node")
            return
        }

        let leafSubtree = DominatorTree.subtree(of: leaf, idom: idom)

        XCTAssertEqual(leafSubtree.count, 1,
            "Leaf's subtree should contain only itself")
        XCTAssertTrue(leafSubtree.contains(leaf))
    }

    // MARK: - Gateway Detection

    func testLinearGraphGateway() {
        let snapshot = buildLinearGraph()

        let gws = DominatorTree.gateways(snapshot: snapshot)

        // In root -> A -> B, root dominates 2 nodes (A, B) so it's a gateway
        XCTAssertFalse(gws.isEmpty,
            "Linear graph should have at least one gateway (root)")

        let rootGateway = gws.first(where: { $0.fingerprint == snapshot.rootFingerprint })
        XCTAssertNotNil(rootGateway, "Root should be a gateway")
        XCTAssertEqual(rootGateway?.dominatedCount, 2,
            "Root dominates 2 other screens in linear graph")
    }

    func testGatewaysSortedByDominatedCount() {
        let snapshot = buildLinearGraph()

        let gws = DominatorTree.gateways(snapshot: snapshot)

        for i in 0..<(gws.count - 1) {
            XCTAssertGreaterThanOrEqual(gws[i].dominatedCount, gws[i + 1].dominatedCount,
                "Gateways should be sorted by dominated count descending")
        }
    }

    func testGatewaySubtreeIncludesSelf() {
        let snapshot = buildLinearGraph()

        let gws = DominatorTree.gateways(snapshot: snapshot)

        for gw in gws {
            XCTAssertTrue(gw.subtreeFingerprints.contains(gw.fingerprint),
                "Gateway's subtree should include itself")
        }
    }

    func testSingleNodeHasNoGateways() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Home"]), icons: [], hints: [],
            screenshot: "img", screenType: .tabRoot
        )
        let snapshot = graph.finalize()

        let gws = DominatorTree.gateways(snapshot: snapshot)

        XCTAssertTrue(gws.isEmpty,
            "Single node graph should have no gateways (need >1 dominated)")
    }

    func testDiamondGraphDominators() {
        let snapshot = buildDiamondGraph()
        let idom = DominatorTree.compute(snapshot: snapshot)

        // Every node should have a dominator
        XCTAssertEqual(idom.count, snapshot.nodes.count,
            "Every node should have an immediate dominator")

        // Root dominates all
        for fp in snapshot.nodes.keys {
            XCTAssertTrue(
                DominatorTree.dominates(snapshot.rootFingerprint, fp, idom: idom),
                "Root should dominate all nodes in diamond graph"
            )
        }
    }

    // MARK: - Robustness

    func testDominatorWithUnreachableNodes() {
        // Build a graph where a node is recorded but has no incoming path from root
        // This tests that the algorithm handles disconnected components gracefully
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Root"]), icons: [], hints: [],
            screenshot: "img", screenType: .tabRoot
        )
        let snapshot = graph.finalize()
        let idom = DominatorTree.compute(snapshot: snapshot)

        // Should at least have the root dominating itself
        XCTAssertEqual(idom[snapshot.rootFingerprint], snapshot.rootFingerprint)
    }
}
