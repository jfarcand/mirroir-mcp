// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for SkillMdGenerator stable wait-step anchors on feed-style screens.
// ABOUTME: Covers infinite-scroll wait-step omission and APP.md tab names as wait anchors.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class SkillMdGeneratorWaitAnchorTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRecipeMatch(scrollBehavior: String) -> RecipeMatch {
        RecipeMatch(
            recipe: ScreenRecipe(
                name: "social-feed", platform: "ios",
                description: "Infinite scrolling feed",
                requiredComponents: [], supportingComponents: [],
                forbiddenComponents: [],
                navigationModel: RecipeNavigationModel(
                    type: "infinite-scroll", backtrack: "tap-tab",
                    scrollBehavior: scrollBehavior, depthPattern: "flat"),
                explorationHints: []),
            score: 10.0, reason: "test")
    }

    private func makeAppDescription(tabs: [String]) -> AppDescription {
        AppDescription(
            appName: "TestApp", schemaVersion: 1, locale: nil, archetype: nil, playable: nil,
            resetBeforeExplore: false, obstacleMode: .auto, context: "",
            obstacles: [], skipElements: [], credentials: [:], hints: [],
            tabs: tabs, tabLayout: nil, deepTabs: [], simulator: nil)
    }

    // MARK: - Infinite-Scroll Wait Omission

    func testInfiniteArchetypeOmitsEphemeralWaitSteps() {
        // Feed-only screen: every candidate is ephemeral content, the recipe
        // declares infinite scroll, and no APP.md anchors are available.
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "Amazing sunset over the bridge", tapX: 205, tapY: 320, confidence: 0.90),
                    TapPoint(text: "Feed caption text", tapX: 205, tapY: 480, confidence: 0.88),
                ],
                hints: [],
                actionType: nil,
                arrivedVia: nil,
                screenshotBase64: "img0"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "FeedApp", goal: "browse feed", screens: screens,
            recipeMatch: makeRecipeMatch(scrollBehavior: "infinite"))

        XCTAssertFalse(result.contains("Wait for"),
            "Infinite-scroll screens without a stable anchor should omit the wait step")
        XCTAssertTrue(result.contains("1. Launch **FeedApp**"),
            "Launch step should still be emitted")
    }

    // MARK: - Tab Name Anchors

    func testWaitStepUsesTabNameOnTabScreen() {
        // Ephemeral caption in the header zone plus the declared tab label at
        // the bottom: the wait step must anchor on the stable tab name.
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "POLISHER", tapX: 205, tapY: 150, confidence: 0.95),
                    TapPoint(text: "Recherche", tapX: 142, tapY: 846, confidence: 0.92),
                ],
                hints: [],
                actionType: nil,
                arrivedVia: nil,
                screenshotBase64: "img0"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "FeedApp", goal: "open search tab", screens: screens,
            appDescription: makeAppDescription(tabs: ["Accueil", "Recherche"]))

        XCTAssertTrue(result.contains("Wait for \"Recherche\" to appear"),
            "Wait step should anchor on the declared tab name")
        XCTAssertFalse(result.contains("Wait for \"POLISHER\""),
            "Ephemeral header-zone text should not be the wait anchor")
    }
}
