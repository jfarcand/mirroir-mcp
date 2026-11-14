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
// ABOUTME: Data model for screen recipes — compositions of components that define app archetypes.
// ABOUTME: Recipes describe expected component patterns, navigation models, and exploration hints.

import Foundation

/// A screen recipe describing an iOS app archetype as a composition of components.
/// Recipes enable app-agnostic screen classification: instead of checking app names,
/// the system matches the detected component set against known archetypes.
struct ScreenRecipe: Sendable {
    /// Unique recipe name (e.g. "settings-list", "dashboard", "social-feed").
    let name: String
    /// Platform identifier (e.g. "ios").
    let platform: String
    /// Human-readable description of the archetype.
    let description: String
    /// Component names that must be present on screen for this recipe to match.
    let requiredComponents: Set<String>
    /// Component names that provide bonus score when present.
    let supportingComponents: Set<String>
    /// Component names whose presence disqualifies this recipe.
    let forbiddenComponents: Set<String>
    /// Navigation model describing how the app archetype is navigated.
    let navigationModel: RecipeNavigationModel
    /// Free-form exploration hints for the AI agent.
    let explorationHints: [String]
}

/// Navigation model extracted from a screen recipe.
struct RecipeNavigationModel: Sendable {
    /// Navigation type: drill-down, card-drill-down, infinite-scroll, grid-browse,
    /// list-to-thread, minimal, form.
    let type: String
    /// Backtrack method: tap-back-chevron, tap-tab, none.
    let backtrack: String
    /// Scroll behavior: finite, infinite.
    let scrollBehavior: String
    /// Depth pattern: linear, card-to-detail, flat, grid-to-detail, list-to-detail.
    let depthPattern: String
    /// Cap on full-page calibration scrolls for screens matching this recipe;
    /// nil = use the exploration budget default.
    let calibrationScrollLimit: Int?

    /// Memberwise init with a default for `calibrationScrollLimit` so recipes
    /// that declare no cap fall back to nil (the exploration budget default applies).
    init(
        type: String,
        backtrack: String,
        scrollBehavior: String,
        depthPattern: String,
        calibrationScrollLimit: Int? = nil
    ) {
        self.type = type
        self.backtrack = backtrack
        self.scrollBehavior = scrollBehavior
        self.depthPattern = depthPattern
        self.calibrationScrollLimit = calibrationScrollLimit
    }
}

/// Result of matching a screen's detected components against all loaded recipes.
struct RecipeMatch: Sendable {
    /// The matched recipe.
    let recipe: ScreenRecipe
    /// Match confidence score (higher = better match).
    let score: Double
    /// Breakdown of how the score was computed.
    let reason: String
}
