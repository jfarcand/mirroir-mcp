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
// ABOUTME: Tests for RecipeMatcher scoring and RecipeParser parsing logic.
// ABOUTME: Validates recipe matching against component sets and recipe .md file parsing.

import XCTest
@testable import mirroir_mcp

final class RecipeMatcherTests: XCTestCase {

    // MARK: - Test Fixtures

    private func makeRecipe(
        name: String,
        required: Set<String>,
        supporting: Set<String> = [],
        forbidden: Set<String> = []
    ) -> ScreenRecipe {
        ScreenRecipe(
            name: name,
            platform: "ios",
            description: "Test recipe",
            requiredComponents: required,
            supportingComponents: supporting,
            forbiddenComponents: forbidden,
            navigationModel: RecipeNavigationModel(
                type: "drill-down", backtrack: "tap-back-chevron",
                scrollBehavior: "finite", depthPattern: "linear"
            ),
            explorationHints: ["hint 1"]
        )
    }

    // MARK: - Matching Tests

    func testMatchesWhenAllRequiredPresent() {
        let recipe = makeRecipe(name: "settings",
                                required: ["table-row-disclosure"])
        let detected: Set<String> = ["table-row-disclosure", "section-header"]
        let match = RecipeMatcher.bestMatch(
            detectedComponents: detected, recipes: [recipe])
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.recipe.name, "settings")
    }

    func testNoMatchWhenRequiredMissing() {
        let recipe = makeRecipe(name: "settings",
                                required: ["table-row-disclosure"])
        let detected: Set<String> = ["section-header", "toggle-row"]
        let match = RecipeMatcher.bestMatch(
            detectedComponents: detected, recipes: [recipe])
        XCTAssertNil(match, "Should not match when required component is missing")
    }

    func testSupportingComponentsBoostScore() {
        let recipe = makeRecipe(name: "settings",
                                required: ["table-row-disclosure"],
                                supporting: ["section-header", "toggle-row"])
        let withSupport: Set<String> = ["table-row-disclosure", "section-header", "toggle-row"]
        let withoutSupport: Set<String> = ["table-row-disclosure"]

        let matchWith = RecipeMatcher.bestMatch(
            detectedComponents: withSupport, recipes: [recipe])
        let matchWithout = RecipeMatcher.bestMatch(
            detectedComponents: withoutSupport, recipes: [recipe])

        XCTAssertNotNil(matchWith)
        XCTAssertNotNil(matchWithout)
        XCTAssertGreaterThan(matchWith!.score, matchWithout!.score)
    }

    func testForbiddenComponentsReduceScore() {
        let recipe = makeRecipe(name: "settings",
                                required: ["table-row-disclosure"],
                                forbidden: ["feed-post"])
        let withForbidden: Set<String> = ["table-row-disclosure", "feed-post"]
        let match = RecipeMatcher.bestMatch(
            detectedComponents: withForbidden, recipes: [recipe])
        // Forbidden penalty (-15) should bring score below required (10) → below threshold
        XCTAssertNil(match, "Forbidden component should disqualify the recipe")
    }

    func testBestMatchSelectsHighestScore() {
        let settings = makeRecipe(name: "settings",
                                  required: ["table-row-disclosure"],
                                  supporting: ["section-header", "toggle-row"])
        let dashboard = makeRecipe(name: "dashboard",
                                   required: ["summary-card"],
                                   supporting: ["metric-display", "tab-bar-item"])

        // Screen with both recipe's required components but more support for dashboard
        let detected: Set<String> = [
            "table-row-disclosure", "summary-card",
            "metric-display", "tab-bar-item",
        ]
        let match = RecipeMatcher.bestMatch(
            detectedComponents: detected, recipes: [settings, dashboard])
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.recipe.name, "dashboard",
                       "Dashboard should win with more supporting components")
    }

    func testNoMatchBelowMinimumThreshold() {
        let recipe = makeRecipe(name: "settings",
                                required: ["table-row-disclosure"],
                                forbidden: ["feed-post", "compose-bar"])
        // Required present but two forbidden → score = 10 - 30 = -20
        let detected: Set<String> = ["table-row-disclosure", "feed-post", "compose-bar"]
        let match = RecipeMatcher.bestMatch(
            detectedComponents: detected, recipes: [recipe])
        XCTAssertNil(match, "Score below threshold should not match")
    }

    func testEmptyRecipeListReturnsNil() {
        let detected: Set<String> = ["table-row-disclosure"]
        let match = RecipeMatcher.bestMatch(
            detectedComponents: detected, recipes: [])
        XCTAssertNil(match)
    }

    func testEmptyComponentSetReturnsNil() {
        let recipe = makeRecipe(name: "settings",
                                required: ["table-row-disclosure"])
        let match = RecipeMatcher.bestMatch(
            detectedComponents: [], recipes: [recipe])
        XCTAssertNil(match)
    }

    // MARK: - Strategy Mapping Tests

    func testInfiniteScrollMapsToSocial() {
        let recipe = ScreenRecipe(
            name: "feed", platform: "ios", description: "Feed",
            requiredComponents: ["feed-post"],
            supportingComponents: [],
            forbiddenComponents: [],
            navigationModel: RecipeNavigationModel(
                type: "infinite-scroll", backtrack: "tap-tab",
                scrollBehavior: "infinite", depthPattern: "flat"),
            explorationHints: [])
        let strategy = RecipeMatcher.strategyFromRecipe(recipe, fallback: .mobile)
        XCTAssertEqual(strategy, .social)
    }

    func testDrillDownMapsToMobile() {
        let recipe = ScreenRecipe(
            name: "settings", platform: "ios", description: "Settings",
            requiredComponents: ["table-row-disclosure"],
            supportingComponents: [],
            forbiddenComponents: [],
            navigationModel: RecipeNavigationModel(
                type: "drill-down", backtrack: "tap-back-chevron",
                scrollBehavior: "finite", depthPattern: "linear"),
            explorationHints: [])
        let strategy = RecipeMatcher.strategyFromRecipe(recipe, fallback: .desktop)
        XCTAssertEqual(strategy, .mobile)
    }

    // MARK: - RecipeParser Tests

    func testParseValidRecipeFile() {
        let content = """
        ---
        version: 1
        name: test-recipe
        platform: ios
        ---

        # Test Recipe

        ## Description

        A test recipe for unit testing.

        ## Required Components

        - table-row-disclosure
        - section-header

        ## Supporting Components

        - toggle-row
        - search-bar

        ## Forbidden Components

        - feed-post

        ## Navigation Model

        - type: drill-down
        - backtrack: tap-back-chevron
        - scroll_behavior: finite
        - depth_pattern: linear

        ## Exploration Hints

        - Tap chevron rows to explore sub-screens
        - Skip toggles during exploration
        """

        let recipe = RecipeParser.parse(content: content)
        XCTAssertNotNil(recipe)
        XCTAssertEqual(recipe?.name, "test-recipe")
        XCTAssertEqual(recipe?.platform, "ios")
        XCTAssertEqual(recipe?.requiredComponents, ["table-row-disclosure", "section-header"])
        XCTAssertEqual(recipe?.supportingComponents, ["toggle-row", "search-bar"])
        XCTAssertEqual(recipe?.forbiddenComponents, ["feed-post"])
        XCTAssertEqual(recipe?.navigationModel.type, "drill-down")
        XCTAssertEqual(recipe?.navigationModel.backtrack, "tap-back-chevron")
        XCTAssertEqual(recipe?.navigationModel.scrollBehavior, "finite")
        XCTAssertEqual(recipe?.explorationHints.count, 2)
    }

    func testParsesCalibrationScrollLimit() {
        let content = """
        ---
        version: 1
        name: capped-recipe
        platform: ios
        ---

        # Capped Recipe

        ## Description

        A recipe declaring a calibration scroll cap.

        ## Required Components

        - feed-post

        ## Navigation Model

        - type: infinite-scroll
        - backtrack: tap-tab
        - scroll_behavior: infinite
        - depth_pattern: flat
        - calibration_scroll_limit: 2
        """

        let recipe = RecipeParser.parse(content: content)
        XCTAssertNotNil(recipe)
        XCTAssertEqual(recipe?.navigationModel.calibrationScrollLimit, 2)
    }

    func testCalibrationScrollLimitDefaultsToNil() {
        let content = """
        ---
        version: 1
        name: uncapped-recipe
        platform: ios
        ---

        # Uncapped Recipe

        ## Description

        A recipe without a calibration scroll cap.

        ## Required Components

        - table-row-disclosure

        ## Navigation Model

        - type: drill-down
        - backtrack: tap-back-chevron
        - scroll_behavior: finite
        - depth_pattern: linear
        """

        let recipe = RecipeParser.parse(content: content)
        XCTAssertNotNil(recipe)
        XCTAssertNil(recipe?.navigationModel.calibrationScrollLimit,
                     "Recipe without calibration_scroll_limit should parse to nil")
    }

    func testParseReturnsNilForMissingName() {
        let content = """
        ---
        version: 1
        platform: ios
        ---

        # No Name

        ## Description

        Missing name field.
        """

        let recipe = RecipeParser.parse(content: content)
        XCTAssertNil(recipe)
    }

    func testParseReturnsNilForEmptyDescription() {
        let content = """
        ---
        version: 1
        name: bad-recipe
        platform: ios
        ---

        # Bad Recipe
        """

        let recipe = RecipeParser.parse(content: content)
        XCTAssertNil(recipe, "Recipe without Description section should fail")
    }

    // MARK: - StrategyDetector.refineWithRecipe Tests

    func testRefineDoesNotOverrideExplicitStrategy() {
        let recipe = makeRecipe(name: "feed", required: ["feed-post"])
        let detected: Set<String> = ["feed-post"]
        let (refined, match) = StrategyDetector.refineWithRecipe(
            current: .desktop,
            detectedComponents: detected,
            recipes: [recipe],
            explicitStrategy: "desktop"
        )
        XCTAssertEqual(refined, .desktop, "Explicit strategy should not be overridden")
        XCTAssertNil(match)
    }

    func testRefineUpdatesStrategyWhenRecipeMatches() {
        let recipe = ScreenRecipe(
            name: "feed", platform: "ios", description: "Feed",
            requiredComponents: ["feed-post"],
            supportingComponents: [],
            forbiddenComponents: [],
            navigationModel: RecipeNavigationModel(
                type: "infinite-scroll", backtrack: "tap-tab",
                scrollBehavior: "infinite", depthPattern: "flat"),
            explorationHints: [])
        let detected: Set<String> = ["feed-post"]
        let (refined, match) = StrategyDetector.refineWithRecipe(
            current: .mobile,
            detectedComponents: detected,
            recipes: [recipe]
        )
        XCTAssertEqual(refined, .social)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.recipe.name, "feed")
    }
}
