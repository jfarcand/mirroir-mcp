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
// ABOUTME: DFSExplorer tests for scout phase behavior and screen plan integration.
// ABOUTME: Covers scouting before diving, scout-to-dive transitions, plan building, and plan invalidation.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class DFSExplorerScoutPlanTests: XCTestCase {

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        makeExplorerElements(texts, startY: startY)
    }

    /// Tab bar items placed at the bottom of the screen. Adding these to a root
    /// screen's elements causes MobileAppStrategy.classifyScreen to return .tabRoot,
    /// which is the only screen type that triggers the scout phase.
    private let tabBarItems: [TapPoint] = [
        TapPoint(text: "Home", tapX: 56, tapY: 850, confidence: 0.95),
        TapPoint(text: "Search", tapX: 158, tapY: 850, confidence: 0.95),
        TapPoint(text: "Profile", tapX: 260, tapY: 850, confidence: 0.95),
    ]

    // MARK: - Scout Phase

    func testExplorerScoutsBeforeDiving() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Tab root screen with enough navigation elements to trigger scouting.
        // Tab bar items at bottom cause classifyScreen to return .tabRoot.
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
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 10, scrollLimit: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // After tapping "General", we arrive at a new screen
        let detailElements = makeElements(["About Phone", "iOS Version"])
        let rootScreen = ScreenDescriber.DescribeResult(
            elements: rootElements, screenshotBase64: "img0"
        )
        let describer = MockExplorerDescriber(screens: [
            // step() OCR: root screen
            rootScreen,
            // After scout tap: new screen
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
            // Backtrack verification: back at root
            rootScreen,
        ])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        if case .continue(let desc) = result {
            XCTAssertTrue(desc.contains("Scouted"),
                "First action on a scoutable screen should be a scout. Got: \(desc)")
        } else {
            XCTFail("Expected .continue with scout, got \(result)")
        }

        // Should have tapped once (scout) + tapped back button once (backtrack)
        XCTAssertEqual(input.taps.count, 2, "Scout should tap element + tap back button")
        let backTaps = input.taps.filter { $0.x < 60 && $0.y < 140 }
        XCTAssertEqual(backTaps.count, 1, "Scout should tap back button immediately")
    }

    func testExplorerAdvancesToDiveAfterScouting() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Tab root screen with 4 navigation elements to trigger scouting
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

        // Use maxScoutsPerScreen: 2 to force early transition to dive
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

        // Scout 1: Item A navigates (root → detail → backtrack verify → root)
        let desc1 = MockExplorerDescriber(screens: [rootScreen, detailScreen, rootScreen])
        let step1 = explorer.step(describer: desc1, input: input, strategy: MobileAppStrategy.self)
        if case .continue(let desc) = step1 {
            XCTAssertTrue(desc.contains("Scouted"), "Step 1 should scout. Got: \(desc)")
        }

        // Scout 2: Item B navigates (root → detail → backtrack verify → root)
        let desc2 = MockExplorerDescriber(screens: [rootScreen, detailScreen, rootScreen])
        let step2 = explorer.step(describer: desc2, input: input, strategy: MobileAppStrategy.self)
        if case .continue(let desc) = step2 {
            XCTAssertTrue(desc.contains("Scouted"), "Step 2 should scout. Got: \(desc)")
        }

        // Step 3: Should now be in dive phase (maxScoutsPerScreen=2 reached)
        let diveDetail = makeElements(["Dive Content", "More Info"])
        let desc3 = MockExplorerDescriber(screens: [
            rootScreen,
            ScreenDescriber.DescribeResult(elements: diveDetail, screenshotBase64: "img_dive"),
        ])
        let step3 = explorer.step(describer: desc3, input: input, strategy: MobileAppStrategy.self)
        if case .continue(let desc) = step3 {
            XCTAssertTrue(desc.contains("Tapped"),
                "Step 3 should dive (normal tap). Got: \(desc)")
        } else {
            XCTFail("Expected .continue for dive step, got \(step3)")
        }
    }

    func testExplorerSkipsScoutOnDetailScreen() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Detail screen: has back button + few navigable elements (<4 triggers detail classification)
        let rootElements = makeElements(["About", "Version"])
        session.capture(
            elements: rootElements,
            hints: ["Back navigation detected"],
            icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget.default
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let afterTap = makeElements(["Build Number", "Serial"])
        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(
                elements: rootElements, hints: ["Back navigation detected"],
                screenshotBase64: "img0"
            ),
            ScreenDescriber.DescribeResult(elements: afterTap, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        // Detail screens should NOT scout — should directly tap (dive behavior)
        if case .continue(let desc) = result {
            XCTAssertTrue(desc.contains("Tapped"),
                "Detail screen should dive directly, not scout. Got: \(desc)")
        } else {
            XCTFail("Expected .continue, got \(result)")
        }
    }

    func testScoutRecordsNavigatedResult() {
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

        // After scout tap → new screen (different elements = different fingerprint)
        let newScreen = makeElements(["About Phone", "Model Name"])
        let describer = MockExplorerDescriber(screens: [
            rootScreen,
            ScreenDescriber.DescribeResult(elements: newScreen, screenshotBase64: "img1"),
            // Backtrack verification: back at root
            rootScreen,
        ])
        let input = MockExplorerInput()

        _ = explorer.step(describer: describer, input: input, strategy: MobileAppStrategy.self)

        // Check that the graph recorded a scout result
        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint
        let results = graph.scoutResults(for: rootFP)
        XCTAssertEqual(results["General"], .navigated,
            "Scout should record .navigated for element that changed the screen")
    }

    func testScoutRecordsNoChangeResult() {
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
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget.default
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // After scout tap → same screen (same elements = same fingerprint)
        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
        ])
        let input = MockExplorerInput()

        _ = explorer.step(describer: describer, input: input, strategy: MobileAppStrategy.self)

        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint
        let results = graph.scoutResults(for: rootFP)
        XCTAssertEqual(results["General"], .noChange,
            "Scout should record .noChange for element that didn't change screen")
    }

    func testScoutBacktracksImmediatelyAfterNavigation() {
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

        let newScreen = makeElements(["Detail View", "Content"])
        let describer = MockExplorerDescriber(screens: [
            rootScreen,
            ScreenDescriber.DescribeResult(elements: newScreen, screenshotBase64: "img1"),
            // Backtrack verification: back at root
            rootScreen,
        ])
        let input = MockExplorerInput()

        _ = explorer.step(describer: describer, input: input, strategy: MobileAppStrategy.self)

        // After scouting a navigated element, graph should be back on root
        let graph = session.currentGraph
        XCTAssertEqual(graph.currentFingerprint, graph.rootFingerprint,
            "After scout backtrack, graph should point to parent screen")

        // Should have exactly 1 tap on the back button (the backtrack)
        let backTaps = input.taps.filter { $0.x < 60 && $0.y < 140 }
        XCTAssertEqual(backTaps.count, 1,
            "Scout should tap back button exactly once after navigation")
    }

    // MARK: - Screen Plan Integration

    func testExplorerBuildsPlanBeforeTapping() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Settings screen with chevron-backed items
        let rootElements: [TapPoint] = [
            TapPoint(text: "General", tapX: 100, tapY: 400, confidence: 0.95),
            TapPoint(text: ">", tapX: 370, tapY: 400, confidence: 0.95),
            TapPoint(text: "Privacy", tapX: 100, tapY: 480, confidence: 0.95),
            TapPoint(text: ">", tapX: 370, tapY: 480, confidence: 0.95),
        ]
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        // Disable scouting to go straight to dive phase
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            maxScoutsPerScreen: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let detailElements = makeElements(["About Phone", "iOS Version"])
        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()

        _ = explorer.step(describer: describer, input: input, strategy: MobileAppStrategy.self)

        // After step, a plan should have been built for the root screen
        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint
        let plan = graph.screenPlan(for: rootFP)
        XCTAssertNotNil(plan, "Explorer should build a screen plan before tapping")
    }

    func testExplorerInvalidatesPlanAfterScroll() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 3,
            maxScoutsPerScreen: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Mark the only element visited so scrolling triggers
        let graph = session.currentGraph
        let fp = graph.currentFingerprint
        graph.markElementVisited(fingerprint: fp, elementText: "Settings")

        // Manually set a plan to verify it gets cleared
        let fakePlan = [
            RankedElement(
                point: TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.9),
                score: 1.0, reason: "test"
            ),
        ]
        graph.setScreenPlan(for: fp, plan: fakePlan)
        XCTAssertNotNil(graph.screenPlan(for: fp), "Plan should exist before scroll")

        // Scroll reveals new elements
        let scrolledElements = makeElements(["General", "Privacy", "About"])
        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: scrolledElements, screenshotBase64: "img0_scrolled"),
        ])
        let input = MockExplorerInput()

        let result = explorer.step(describer: describer, input: input, strategy: MobileAppStrategy.self)

        if case .continue(let desc) = result {
            XCTAssertTrue(desc.contains("Scrolled"), "Should scroll. Got: \(desc)")
        } else {
            XCTFail("Expected .continue after scroll, got \(result)")
        }

        // Plan should be cleared after scroll revealed new elements
        XCTAssertNil(graph.screenPlan(for: fp),
            "Plan should be invalidated after scroll reveals new elements")
    }

    func testPlanPrioritizesChevronElements() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Mix of chevron-backed and fallback navigation elements.
        // Y-sorted plan taps top-to-bottom, so General (y=240) is tapped first.
        let rootElements: [TapPoint] = [
            // Chevron-backed at top
            TapPoint(text: "General", tapX: 100, tapY: 240, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 240, confidence: 0.9),
            // Fallback (no chevron) mid-screen
            TapPoint(text: "Identifiant Apple", tapX: 200, tapY: 450, confidence: 0.9),
        ]
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        // Disable scouting
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            maxScoutsPerScreen: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let detailElements = makeElements(["About Phone", "iOS Version"])
        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()

        let result = explorer.step(describer: describer, input: input, strategy: MobileAppStrategy.self)

        if case .continue(let desc) = result {
            // The plan should prioritize "General" (chevron) over "Identifiant Apple" (fallback)
            XCTAssertTrue(desc.contains("General"),
                "Explorer should tap chevron-backed \"General\" first, not fallback. Got: \(desc)")
        } else {
            XCTFail("Expected .continue, got \(result)")
        }
    }

}
