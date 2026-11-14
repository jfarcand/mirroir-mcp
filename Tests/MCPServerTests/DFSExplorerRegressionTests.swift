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
// ABOUTME: Regression tests for DFS exploration bug fixes: scout visited marking, similarity-based
// ABOUTME: navigation detection, backtrack verification, and scout-dive plan integration.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class DFSExplorerRegressionTests: XCTestCase {

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        makeExplorerElements(texts, startY: startY)
    }

    /// Tab bar items for making screens classify as .tabRoot (only scoutable type).
    private let tabBarItems: [TapPoint] = [
        TapPoint(text: "Home", tapX: 56, tapY: 850, confidence: 0.95),
        TapPoint(text: "Search", tapX: 158, tapY: 850, confidence: 0.95),
        TapPoint(text: "Profile", tapX: 260, tapY: 850, confidence: 0.95),
    ]

    // MARK: - Scout Does Not Mark Elements Visited

    func testScoutDoesNotMarkElementsAsVisited() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements: [TapPoint] = [
            TapPoint(text: "General", tapX: 100, tapY: 200, confidence: 0.95),
            TapPoint(text: ">", tapX: 370, tapY: 200, confidence: 0.95),
            TapPoint(text: "Privacy", tapX: 100, tapY: 280, confidence: 0.95),
            TapPoint(text: ">", tapX: 370, tapY: 280, confidence: 0.95),
            TapPoint(text: "Display", tapX: 100, tapY: 360, confidence: 0.95),
            TapPoint(text: ">", tapX: 370, tapY: 360, confidence: 0.95),
            TapPoint(text: "Storage", tapX: 100, tapY: 440, confidence: 0.95),
            TapPoint(text: ">", tapX: 370, tapY: 440, confidence: 0.95),
        ] + tabBarItems
        let rootScreen = ScreenDescriber.DescribeResult(
            elements: rootElements, screenshotBase64: "img0"
        )
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget.default
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Scout "General" → navigates to a new screen
        let detailScreen = ScreenDescriber.DescribeResult(
            elements: makeElements(["About Phone", "Model Name"]),
            screenshotBase64: "img1"
        )
        let describer = MockExplorerDescriber(screens: [
            rootScreen, detailScreen, rootScreen,
        ])
        let input = MockExplorerInput()

        _ = explorer.step(describer: describer, input: input, strategy: MobileAppStrategy.self)

        // After scouting, the parent screen's visitedElements should be empty.
        // Scout deduplication uses scoutResultsMap, not visitedElements.
        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint
        let node = graph.node(for: rootFP)
        XCTAssertNotNil(node)
        XCTAssertTrue(node?.visitedElements.isEmpty ?? false,
            "Scout should NOT mark elements as visited. visitedElements = \(node?.visitedElements ?? [])")
    }

    // MARK: - Dive Plan Includes Scouted Elements

    func testDivePlanIncludesScoutedElements() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // 4 navigation elements, scout budget of 2 (tab root to enable scouting)
        let rootElements: [TapPoint] = [
            TapPoint(text: "Item A", tapX: 100, tapY: 200, confidence: 0.95),
            TapPoint(text: ">", tapX: 370, tapY: 200, confidence: 0.95),
            TapPoint(text: "Item B", tapX: 100, tapY: 280, confidence: 0.95),
            TapPoint(text: ">", tapX: 370, tapY: 280, confidence: 0.95),
            TapPoint(text: "Item C", tapX: 100, tapY: 360, confidence: 0.95),
            TapPoint(text: ">", tapX: 370, tapY: 360, confidence: 0.95),
            TapPoint(text: "Item D", tapX: 100, tapY: 440, confidence: 0.95),
            TapPoint(text: ">", tapX: 370, tapY: 440, confidence: 0.95),
        ] + tabBarItems
        let rootScreen = ScreenDescriber.DescribeResult(
            elements: rootElements, screenshotBase64: "img0"
        )
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 10, scrollLimit: 0,
            maxScoutsPerScreen: 2,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let input = MockExplorerInput()
        let detailScreen = ScreenDescriber.DescribeResult(
            elements: makeElements(["Detail Info"]), screenshotBase64: "img_detail"
        )

        // Scout Item A and Item B (2 scouts = budget)
        for _ in 0..<2 {
            let desc = MockExplorerDescriber(screens: [rootScreen, detailScreen, rootScreen])
            _ = explorer.step(describer: desc, input: input, strategy: MobileAppStrategy.self)
        }

        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint

        // Dive phase starts next step — force a build step
        let diveDetail = makeElements(["Dive Content"])
        let desc3 = MockExplorerDescriber(screens: [
            rootScreen,
            ScreenDescriber.DescribeResult(elements: diveDetail, screenshotBase64: "img_dive"),
        ])
        let step3 = explorer.step(describer: desc3, input: input, strategy: MobileAppStrategy.self)

        if case .continue(let desc) = step3 {
            // The scouted elements (Item A, Item B) with .navigated result should be
            // in the dive plan and scored higher. The dive should tap one of them.
            XCTAssertTrue(desc.contains("Tapped"),
                "Dive should tap an element (including scouted ones). Got: \(desc)")
        } else {
            XCTFail("Expected .continue for dive, got \(step3)")
        }

        // Verify the plan was built and includes scouted-navigated elements
        let builtPlan = graph.screenPlan(for: rootFP)
        XCTAssertNotNil(builtPlan, "Dive plan should be built")
        let planTexts = builtPlan?.map(\.point.text) ?? []
        // Item A and Item B were scouted as navigated — they should be in the plan
        // because they were NOT marked visited during scouting
        let scoutedInPlan = planTexts.filter { $0 == "Item A" || $0 == "Item B" }
        XCTAssertFalse(scoutedInPlan.isEmpty,
            "Scouted-navigated elements should remain in the dive plan. Plan: \(planTexts)")
    }

    // MARK: - Scout Uses Similarity Not Exact Hash

    func testScoutUsesSimilarityNotExactHash() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Root screen with 10 elements for high similarity matching (tab root to enable scouting)
        let rootTexts = ["Item A", "Item B", "Item C", "Item D", "Item E",
                         "Item F", "Item G", "Item H", "Item I", "Item J"]
        let rootElements: [TapPoint] = rootTexts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 100, tapY: 200 + Double(i) * 40, confidence: 0.95)
        } + rootTexts.enumerated().map { (i, _) in
            TapPoint(text: ">", tapX: 370, tapY: 200 + Double(i) * 40, confidence: 0.95)
        } + tabBarItems
        let rootScreen = ScreenDescriber.DescribeResult(
            elements: rootElements, screenshotBase64: "img0"
        )
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget.default
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // After scout tap, return nearly identical screen with 1 minor OCR variation.
        // Exact hash would differ, but similarity (9/11 = 0.818 > 0.8) should detect same screen.
        var similarTexts = rootTexts
        similarTexts[9] = "Item J2"  // One minor OCR variation
        let similarElements: [TapPoint] = similarTexts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 100, tapY: 200 + Double(i) * 40, confidence: 0.95)
        } + similarTexts.enumerated().map { (i, _) in
            TapPoint(text: ">", tapX: 370, tapY: 200 + Double(i) * 40, confidence: 0.95)
        } + tabBarItems
        let similarScreen = ScreenDescriber.DescribeResult(
            elements: similarElements, screenshotBase64: "img0_similar"
        )

        let describer = MockExplorerDescriber(screens: [rootScreen, similarScreen])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        // With similarity-based comparison, minor OCR variation should NOT be
        // detected as navigation. Scout should record .noChange.
        if case .continue(let desc) = result {
            XCTAssertTrue(desc.contains("no navigation"),
                "Minor OCR variation should not be detected as navigation. Got: \(desc)")
        } else {
            XCTFail("Expected .continue, got \(result)")
        }

        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint
        let results = graph.scoutResults(for: rootFP)
        XCTAssertEqual(results["Item A"], .noChange,
            "Similarity-based scout should record .noChange for minor OCR variation")
    }
}
