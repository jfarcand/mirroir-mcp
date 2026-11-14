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
// ABOUTME: Unit tests for SocialAppStrategy: social-specific skip patterns, depth caps, and delegation.
// ABOUTME: Verifies that MobileAppStrategy delegation works and social enhancements layer correctly.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class SocialAppStrategyTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        texts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 205, tapY: startY + Double(i) * 80, confidence: 0.95)
        }
    }

    // MARK: - Classification Delegation

    func testClassifyScreenDelegatesToMobile() {
        // Tab bar screen should be classified same as MobileAppStrategy
        let elements = makeElements(["Home", "Search", "Profile", "Settings", "More"], startY: 800)
        let result = SocialAppStrategy.classifyScreen(elements: elements, hints: [])
        let mobileResult = MobileAppStrategy.classifyScreen(elements: elements, hints: [])
        XCTAssertEqual(result, mobileResult,
            "SocialAppStrategy should delegate classifyScreen to MobileAppStrategy")
    }

    // MARK: - Skip Patterns

    func testSkipsSocialEngagementElements() {
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0, skipPatterns: []
        )
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "Sponsored Post", budget: budget))
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "Promoted", budget: budget))
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "Follow", budget: budget))
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "Unfollow", budget: budget))
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "Share", budget: budget))
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "Repost", budget: budget))
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "Upvote", budget: budget))
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "Downvote", budget: budget))
    }

    func testSkipsSocialPatternsCaseInsensitive() {
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0, skipPatterns: []
        )
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "SPONSORED", budget: budget))
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "stories", budget: budget))
    }

    func testSkipInheritsBasePatterns() {
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0, skipPatterns: ["Delete", "Sign Out"]
        )
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "Delete Account", budget: budget))
        XCTAssertTrue(SocialAppStrategy.shouldSkip(elementText: "Sign Out", budget: budget))
    }

    func testDoesNotSkipSafeNavElements() {
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0, skipPatterns: ["Delete"]
        )
        XCTAssertFalse(SocialAppStrategy.shouldSkip(elementText: "Home", budget: budget))
        XCTAssertFalse(SocialAppStrategy.shouldSkip(elementText: "Search", budget: budget))
        XCTAssertFalse(SocialAppStrategy.shouldSkip(elementText: "Profile", budget: budget))
        XCTAssertFalse(SocialAppStrategy.shouldSkip(elementText: "Settings", budget: budget))
    }

    // MARK: - Ranking Filters

    func testRankingFiltersSocialSkipPatterns() {
        let elements = makeElements(["Home", "Sponsored Post", "Settings", "Upvote", "About"])
        let ranked = SocialAppStrategy.rankElements(
            elements: elements, icons: [],
            visitedElements: [], depth: 0, screenType: .list
        )

        let rankedTexts = ranked.map(\.text)
        XCTAssertFalse(rankedTexts.contains("Sponsored Post"),
            "Sponsored content should be filtered from ranking")
        XCTAssertFalse(rankedTexts.contains("Upvote"),
            "Upvote should be filtered from ranking")
        XCTAssertTrue(rankedTexts.contains("Home"))
        XCTAssertTrue(rankedTexts.contains("Settings"))
        XCTAssertTrue(rankedTexts.contains("About"))
    }

    // MARK: - Terminal at Profile Depth

    func testTerminalAtProfileDepthCap() {
        let elements = makeElements(["User Profile", "Posts", "Comments"])
        let result = SocialAppStrategy.isTerminal(
            elements: elements, depth: 3,
            budget: .default, screenType: .detail
        )
        XCTAssertTrue(result,
            "Detail screen at depth >= 3 should be terminal in social strategy")
    }

    func testNotTerminalBelowProfileDepthCap() {
        let elements = makeElements(["User Profile", "Posts", "Comments"])
        let result = SocialAppStrategy.isTerminal(
            elements: elements, depth: 2,
            budget: .default, screenType: .detail
        )
        XCTAssertFalse(result,
            "Detail screen at depth < 3 should not be terminal")
    }

    func testTerminalStillRespectsBaseBudgetDepth() {
        let elements = makeElements(["Settings", "About", "Version"])
        let result = SocialAppStrategy.isTerminal(
            elements: elements, depth: 6,
            budget: .default, screenType: .list
        )
        XCTAssertTrue(result,
            "Should respect base budget max depth regardless of screen type")
    }

    // MARK: - Backtrack Delegation

    func testBacktrackDelegatesToMobile() {
        let hints = ["Back navigation detected"]
        let social = SocialAppStrategy.backtrackMethod(currentHints: hints, depth: 2)
        let mobile = MobileAppStrategy.backtrackMethod(currentHints: hints, depth: 2)
        XCTAssertEqual(social, mobile,
            "Backtrack should delegate to MobileAppStrategy")
    }

    // MARK: - Fingerprint Delegation

    func testFingerprintDelegatesToMobile() {
        let elements = makeElements(["Test", "Screen"])
        let social = SocialAppStrategy.extractFingerprint(elements: elements, icons: [])
        let mobile = MobileAppStrategy.extractFingerprint(elements: elements, icons: [])
        XCTAssertEqual(social, mobile,
            "Fingerprint should delegate to MobileAppStrategy")
    }
}
