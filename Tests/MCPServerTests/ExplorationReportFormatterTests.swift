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
// ABOUTME: Unit tests for ExplorationReportFormatter graph-structure rendering.
// ABOUTME: Verifies DominatorTree gateways + GraphAnalyzer rooms surface in the report.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ExplorationReportFormatterTests: XCTestCase {

    private func makeElements(_ texts: [String]) -> [TapPoint] {
        texts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 205, tapY: 120 + Double(i) * 80, confidence: 0.95)
        }
    }

    /// root -> A -> B: A is a gateway that dominates B.
    private func buildLinearSnapshot() -> GraphSnapshot {
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

    func testFormatGraphStructureRendersRoomsAndGateways() {
        let snapshot = buildLinearSnapshot()
        let out = ExplorationReportFormatter.formatGraphStructure(snapshot: snapshot)

        XCTAssertTrue(out.contains("## Graph Structure"), "missing header in:\n\(out)")
        XCTAssertTrue(out.contains("- Rooms:"), "missing rooms line in:\n\(out)")
        // A linear root->A->B graph has at least one gateway (root and/or A
        // dominate downstream screens), so the chokepoint line must appear.
        XCTAssertTrue(
            out.contains("Gateway screens (chokepoints"),
            "expected gateway chokepoints in:\n\(out)"
        )
        XCTAssertTrue(out.contains("dominates"), "expected a 'dominates N screens' line in:\n\(out)")
    }

    func testReportIncludesGraphStructureSectionWhenProvided() {
        let snapshot = buildLinearSnapshot()
        let structure = ExplorationReportFormatter.formatGraphStructure(snapshot: snapshot)
        let report = ExplorationReportFormatter.formatExplorationReport(
            appName: "Settings",
            calibration: nil,
            screens: [],
            stats: (nodeCount: 3, edgeCount: 2, actionCount: 2, elapsedSeconds: 5),
            tapCacheTotal: 0,
            graphStructure: structure
        )
        XCTAssertTrue(report.contains("## Graph Structure"), "report omitted graph structure")
        XCTAssertTrue(report.contains("# Exploration Report: Settings"))
    }

    func testReportOmitsGraphStructureWhenNil() {
        let report = ExplorationReportFormatter.formatExplorationReport(
            appName: "Settings",
            calibration: nil,
            screens: [],
            stats: (nodeCount: 1, edgeCount: 0, actionCount: 0, elapsedSeconds: 1),
            tapCacheTotal: 0
        )
        XCTAssertFalse(report.contains("## Graph Structure"), "graph structure must be opt-in")
    }
}
