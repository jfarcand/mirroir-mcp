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
// ABOUTME: Unit tests for ExplorationBudget: limit enforcement and element skip patterns.
// ABOUTME: Verifies depth, screen count, time limits, and dangerous action filtering.

import XCTest
@testable import mirroir_mcp

final class ExplorationBudgetTests: XCTestCase {

    // MARK: - Default Budget

    func testDefaultBudgetValues() {
        let budget = ExplorationBudget.default

        XCTAssertEqual(budget.maxDepth, 6)
        XCTAssertEqual(budget.maxScreens, 30)
        XCTAssertEqual(budget.maxTimeSeconds, 300)
        XCTAssertEqual(budget.maxActionsPerScreen, 5)
        XCTAssertEqual(budget.scrollLimit, 3)
        XCTAssertEqual(budget.calibrationScrollLimit, 15)
        XCTAssertFalse(budget.skipPatterns.isEmpty, "Default budget includes built-in safety skip patterns")
    }

    // MARK: - isExhausted

    func testNotExhaustedWithinLimits() {
        let budget = ExplorationBudget.default

        XCTAssertFalse(budget.isExhausted(depth: 3, screenCount: 10, elapsedSeconds: 60))
    }

    func testExhaustedByDepth() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.isExhausted(depth: 6, screenCount: 5, elapsedSeconds: 30))
    }

    func testExhaustedByScreenCount() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.isExhausted(depth: 2, screenCount: 30, elapsedSeconds: 30))
    }

    func testExhaustedByTime() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.isExhausted(depth: 2, screenCount: 5, elapsedSeconds: 300))
    }

    func testCustomBudgetLimits() {
        let budget = ExplorationBudget(
            maxDepth: 3,
            maxScreens: 10,
            maxTimeSeconds: 60,
            maxActionsPerScreen: 3,
            scrollLimit: 2,
            skipPatterns: ["Delete"]
        )

        XCTAssertFalse(budget.isExhausted(depth: 2, screenCount: 9, elapsedSeconds: 59))
        XCTAssertTrue(budget.isExhausted(depth: 3, screenCount: 5, elapsedSeconds: 30))
        XCTAssertTrue(budget.isExhausted(depth: 1, screenCount: 10, elapsedSeconds: 30))
        XCTAssertTrue(budget.isExhausted(depth: 1, screenCount: 5, elapsedSeconds: 60))
    }

    func testCustomCalibrationScrollLimit() {
        let budget = ExplorationBudget(
            maxDepth: 3,
            maxScreens: 10,
            maxTimeSeconds: 60,
            maxActionsPerScreen: 3,
            scrollLimit: 2,
            calibrationScrollLimit: 20,
            skipPatterns: []
        )

        XCTAssertEqual(budget.scrollLimit, 2)
        XCTAssertEqual(budget.calibrationScrollLimit, 20)
    }

    func testCalibrationScrollLimitPassesThroughMerge() {
        let budget = ExplorationBudget(
            maxDepth: 3,
            maxScreens: 10,
            maxTimeSeconds: 60,
            maxActionsPerScreen: 3,
            scrollLimit: 2,
            calibrationScrollLimit: 25,
            skipPatterns: []
        )

        let merged = budget.mergedWith(["extra"])
        XCTAssertEqual(merged.calibrationScrollLimit, 25,
            "calibrationScrollLimit should pass through mergedWith()")
        XCTAssertEqual(merged.scrollLimit, 2)
    }

    // MARK: - shouldSkipElement

    func testSkipDestructiveActions() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "Delete Account"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Sign Out"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Log Out"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Reset All Settings"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Erase All Content"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Remove All"))
    }

    func testSkipIsCaseInsensitive() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "delete account"))
        XCTAssertTrue(budget.shouldSkipElement(text: "SIGN OUT"))
    }

    func testDoNotSkipSafeElements() {
        let budget = ExplorationBudget.default

        XCTAssertFalse(budget.shouldSkipElement(text: "General"))
        XCTAssertFalse(budget.shouldSkipElement(text: "About"))
        XCTAssertFalse(budget.shouldSkipElement(text: "Privacy"))
        XCTAssertFalse(budget.shouldSkipElement(text: "Display & Brightness"))
    }

    // MARK: - Network Toggles

    func testSkipNetworkToggles() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "Airplane Mode"))
    }

    // MARK: - Ad/Sponsored Content

    func testSkipsAdContent() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "Sponsored"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Promoted Post"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Advertisement"))
        XCTAssertTrue(budget.shouldSkipElement(text: "ORDER NOW"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Buy Now"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Install Now"))
    }

    func testSkipsAdContentCaseInsensitive() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "sponsored content"))
        XCTAssertTrue(budget.shouldSkipElement(text: "buy now button"))
    }

    // MARK: - Purchase Actions

    func testSkipPurchaseActions() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "Subscribe Now"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Purchase"))
    }

    // MARK: - Regex Skip Patterns

    private func makeBudget(patterns: [String]) -> ExplorationBudget {
        ExplorationBudget(
            maxDepth: 3, maxScreens: 10, maxTimeSeconds: 60,
            maxActionsPerScreen: 5, scrollLimit: 3, skipPatterns: patterns)
    }

    func testSlashWrappedPatternMatchesAsRegex() {
        // The Instagram like-count row whose "Aimé par" prefix OCR drops:
        // "et N autres" must match for any count without a literal "autres"
        // entry that would also block an "Autres" nav label.
        let budget = makeBudget(patterns: [#"/et \d+ autres/"#])

        XCTAssertTrue(budget.shouldSkipElement(
            text: "rearcand, egignac, colin.stcyr_ et 64 autres"))
        XCTAssertTrue(budget.shouldSkipElement(text: "marie et 3 autres"))
        XCTAssertFalse(budget.shouldSkipElement(text: "Autres"),
            "A bare nav label must not match the count-specific regex")
        XCTAssertFalse(budget.shouldSkipElement(text: "et autres choses"),
            "Without a count the regex must not match")
    }

    func testRegexMatchingIsCaseInsensitive() {
        let budget = makeBudget(patterns: [#"/et \d+ autres/"#])
        XCTAssertTrue(budget.shouldSkipElement(text: "Rearcand ET 12 AUTRES"))
    }

    func testInvalidRegexFallsBackToLiteralSubstring() {
        // "/[/" does not compile; the whole entry is then matched literally,
        // so only text containing the literal "/[/" is skipped.
        let budget = makeBudget(patterns: ["/[/"])

        XCTAssertTrue(budget.shouldSkipElement(text: "path /[/ fragment"))
        XCTAssertFalse(budget.shouldSkipElement(text: "ordinary label"))
    }

    func testPlainEntriesStillMatchAsSubstrings() {
        let budget = makeBudget(patterns: ["Plus tard", #"/et \d+ autres/"#])

        XCTAssertTrue(budget.shouldSkipElement(text: "Plus tard • Télécharger"))
        XCTAssertTrue(budget.shouldSkipElement(text: "a et 5 autres b"))
        XCTAssertFalse(budget.shouldSkipElement(text: "Paramètres"))
    }

    func testLoneSlashIsNotTreatedAsRegex() {
        // "/" is a plausible literal label; only /.../ with content in between
        // (length > 2) enters the regex path.
        let budget = makeBudget(patterns: ["/"])
        XCTAssertTrue(budget.shouldSkipElement(text: "On/Off"))
    }
}
