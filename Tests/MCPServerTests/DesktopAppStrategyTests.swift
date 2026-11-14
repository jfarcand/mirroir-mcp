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
// ABOUTME: Unit tests for DesktopAppStrategy: desktop-specific screen classification and element ranking.
// ABOUTME: Verifies dialog detection, sidebar ranking, desktop skip patterns, and terminal conditions.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class DesktopAppStrategyTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeElements(_ specs: [(String, Double, Double)]) -> [TapPoint] {
        specs.map { (text, x, y) in
            TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
        }
    }

    // MARK: - Screen Classification

    func testClassifiesDialogAsModal() {
        let elements = makeElements([
            ("Are you sure?", 200, 200),
            ("Cancel", 150, 300),
            ("OK Button", 250, 300),
        ])
        let result = DesktopAppStrategy.classifyScreen(elements: elements, hints: [])
        XCTAssertEqual(result, .modal,
            "Screen with Cancel/OK and few elements should be classified as modal")
    }

    func testClassifiesSidebarLayout() {
        let elements = makeElements([
            ("General", 100, 120),
            ("Appearance", 100, 200),
            ("Privacy", 100, 280),
            ("Advanced", 100, 360),
            ("Content Area", 350, 200),
        ])
        let result = DesktopAppStrategy.classifyScreen(elements: elements, hints: [])
        XCTAssertEqual(result, .settings,
            "Screen with 3+ low-X elements should be classified as settings/sidebar")
    }

    func testClassifiesContentRichAsList() {
        let elements = makeElements([
            ("Item One", 300, 120),
            ("Item Two", 300, 200),
            ("Item Three", 300, 280),
            ("Item Four", 300, 360),
        ])
        let result = DesktopAppStrategy.classifyScreen(elements: elements, hints: [])
        XCTAssertEqual(result, .list,
            "Screen with 4+ navigable elements should be classified as list")
    }

    func testClassifiesSparseAsDetail() {
        let elements = makeElements([
            ("Document Title", 200, 200),
            ("Page Content", 200, 400),
        ])
        let result = DesktopAppStrategy.classifyScreen(elements: elements, hints: [])
        XCTAssertEqual(result, .detail,
            "Sparse screen with few elements should be classified as detail")
    }

    // MARK: - Element Ranking

    func testSidebarItemsRankedFirst() {
        let elements = makeElements([
            ("Content Item", 300, 200),
            ("Sidebar Nav", 100, 150),
            ("Another Sidebar", 80, 250),
        ])
        let ranked = DesktopAppStrategy.rankElements(
            elements: elements, icons: [],
            visitedElements: [], depth: 0, screenType: .settings
        )

        let rankedTexts = ranked.map(\.text)
        guard rankedTexts.count >= 2 else {
            XCTFail("Expected at least 2 ranked elements")
            return
        }
        // Sidebar items (tapX < 200) should come before content items
        let sidebarIndex = rankedTexts.firstIndex(of: "Sidebar Nav")
        let contentIndex = rankedTexts.firstIndex(of: "Content Item")
        XCTAssertNotNil(sidebarIndex)
        XCTAssertNotNil(contentIndex)
        if let si = sidebarIndex, let ci = contentIndex {
            XCTAssertLessThan(si, ci,
                "Sidebar items should be ranked before content items")
        }
    }

    func testVisitedElementsDeprioritized() {
        let elements = makeElements([
            ("General", 100, 120),
            ("Privacy", 100, 200),
            ("Advanced", 100, 280),
        ])
        let ranked = DesktopAppStrategy.rankElements(
            elements: elements, icons: [],
            visitedElements: ["General"], depth: 0, screenType: .settings
        )

        let rankedTexts = ranked.map(\.text)
        guard let generalIdx = rankedTexts.firstIndex(of: "General"),
              let privacyIdx = rankedTexts.firstIndex(of: "Privacy") else {
            XCTFail("Expected General and Privacy in results")
            return
        }
        XCTAssertGreaterThan(generalIdx, privacyIdx,
            "Visited elements should be ranked after unvisited")
    }

    // MARK: - Skip Patterns

    func testSkipsDesktopDestructiveActions() {
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0, skipPatterns: []
        )
        // Desktop-specific patterns are built into the strategy
        XCTAssertTrue(DesktopAppStrategy.shouldSkip(elementText: "Quit App", budget: budget))
        XCTAssertTrue(DesktopAppStrategy.shouldSkip(elementText: "Force Quit", budget: budget))
        XCTAssertTrue(DesktopAppStrategy.shouldSkip(elementText: "Format Disk", budget: budget))
        XCTAssertTrue(DesktopAppStrategy.shouldSkip(elementText: "Uninstall", budget: budget))
    }

    func testSkipInheritsBasePatterns() {
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0, skipPatterns: ["Delete", "Sign Out"]
        )
        XCTAssertTrue(DesktopAppStrategy.shouldSkip(elementText: "Delete", budget: budget))
        XCTAssertTrue(DesktopAppStrategy.shouldSkip(elementText: "Sign Out", budget: budget))
    }

    func testDoesNotSkipSafeDesktopElements() {
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0, skipPatterns: ["Delete"]
        )
        XCTAssertFalse(DesktopAppStrategy.shouldSkip(elementText: "General", budget: budget))
        XCTAssertFalse(DesktopAppStrategy.shouldSkip(elementText: "Preferences", budget: budget))
        XCTAssertFalse(DesktopAppStrategy.shouldSkip(elementText: "About", budget: budget))
    }

    // MARK: - Terminal Conditions

    func testModalIsTerminal() {
        let elements = makeElements([
            ("OK Button", 200, 300),
            ("Cancel", 150, 300),
        ])
        let result = DesktopAppStrategy.isTerminal(
            elements: elements, depth: 1, budget: .default, screenType: .modal
        )
        XCTAssertTrue(result, "Modal screens should be terminal")
    }

    func testSparseDetailIsTerminal() {
        let elements = makeElements([
            ("Only Element", 200, 200),
        ])
        let result = DesktopAppStrategy.isTerminal(
            elements: elements, depth: 1, budget: .default, screenType: .detail
        )
        XCTAssertTrue(result, "Sparse detail screen should be terminal")
    }

    func testBudgetDepthIsTerminal() {
        let elements = makeElements([
            ("Item One", 200, 120),
            ("Item Two", 200, 200),
            ("Item Three", 200, 280),
        ])
        let result = DesktopAppStrategy.isTerminal(
            elements: elements, depth: 6, budget: .default, screenType: .list
        )
        XCTAssertTrue(result, "Exceeding budget depth should be terminal")
    }

    func testNonTerminalListScreen() {
        let elements = makeElements([
            ("Item One", 200, 120),
            ("Item Two", 200, 200),
            ("Item Three", 200, 280),
        ])
        let result = DesktopAppStrategy.isTerminal(
            elements: elements, depth: 2, budget: .default, screenType: .list
        )
        XCTAssertFalse(result, "Normal list screen within budget should not be terminal")
    }

    // MARK: - Backtrack

    func testBacktrackUsesCommandBracket() {
        let result = DesktopAppStrategy.backtrackMethod(currentHints: [], depth: 2)
        XCTAssertEqual(result, .pressBack,
            "Desktop backtrack should use Cmd+[ (pressBack)")
    }

    func testBacktrackAtRootIsNone() {
        let result = DesktopAppStrategy.backtrackMethod(currentHints: [], depth: 0)
        XCTAssertEqual(result, .none,
            "At root depth, backtrack should be .none")
    }
}
