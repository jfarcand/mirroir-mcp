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
// ABOUTME: Scores a screen's detected components against loaded recipes to find the best archetype.
// ABOUTME: Pure transformation: stateless scoring with no stored properties.

import Foundation
import HelperLib

/// Matches a screen's detected component set against loaded recipes to identify the
/// app archetype. Replaces app-name-based strategy detection with component-composition
/// analysis that works on any app, even unseen ones.
enum RecipeMatcher {

    // MARK: - Scoring Weights

    /// Points per required component that is present on screen.
    static let requiredComponentWeight: Double = 10.0
    /// Points per supporting component that is present on screen.
    static let supportingComponentWeight: Double = 3.0
    /// Penalty per forbidden component that is present on screen.
    static let forbiddenComponentPenalty: Double = -15.0
    /// Minimum score to accept a recipe match (avoids weak matches).
    static let minimumMatchScore: Double = 8.0

    // MARK: - Matching

    /// Find the best-matching recipe for a set of detected component names.
    ///
    /// - Parameters:
    ///   - detectedComponents: Set of component kind names found on the current screen
    ///     (e.g. ["table-row-disclosure", "section-header", "tab-bar-item"]).
    ///   - recipes: All loaded recipe definitions to score against.
    /// - Returns: The best matching recipe above the minimum threshold, or nil if no recipe matches.
    static func bestMatch(
        detectedComponents: Set<String>,
        recipes: [ScreenRecipe]
    ) -> RecipeMatch? {
        var bestMatch: RecipeMatch?

        for recipe in recipes {
            let (score, reason) = computeScore(
                recipe: recipe, detectedComponents: detectedComponents)

            guard score >= minimumMatchScore else { continue }

            if let current = bestMatch, score <= current.score { continue }
            bestMatch = RecipeMatch(recipe: recipe, score: score, reason: reason)
        }

        if let match = bestMatch {
            DebugLog.log("recipes",
                "Matched recipe '\(match.recipe.name)' (score=\(String(format: "%.1f", match.score))): \(match.reason)")
        }

        return bestMatch
    }

    /// Map a recipe match to a StrategyChoice for backward compatibility.
    /// Falls back to the provided default if no recipe-specific mapping exists.
    static func strategyFromRecipe(_ recipe: ScreenRecipe, fallback: StrategyChoice) -> StrategyChoice {
        switch recipe.navigationModel.type {
        case "infinite-scroll":
            return .social
        case "drill-down", "card-drill-down", "form", "list-to-thread", "grid-browse", "minimal":
            return .mobile
        default:
            return fallback
        }
    }

    // MARK: - Private

    /// Compute a match score for a recipe against detected components.
    private static func computeScore(
        recipe: ScreenRecipe,
        detectedComponents: Set<String>
    ) -> (Double, String) {
        var score: Double = 0
        var reasons: [String] = []

        // Required components: each present one adds points
        let requiredPresent = recipe.requiredComponents.intersection(detectedComponents)
        let requiredMissing = recipe.requiredComponents.subtracting(detectedComponents)

        // All required components must be present for a valid match
        guard requiredMissing.isEmpty else {
            return (0, "missing required: \(requiredMissing.sorted().joined(separator: ", "))")
        }

        let requiredScore = Double(requiredPresent.count) * requiredComponentWeight
        score += requiredScore
        reasons.append("required(\(requiredPresent.count)/\(recipe.requiredComponents.count))=\(Int(requiredScore))")

        // Supporting components: bonus for each present
        let supportingPresent = recipe.supportingComponents.intersection(detectedComponents)
        if !supportingPresent.isEmpty {
            let supportingScore = Double(supportingPresent.count) * supportingComponentWeight
            score += supportingScore
            reasons.append("supporting(\(supportingPresent.count))=+\(Int(supportingScore))")
        }

        // Forbidden components: penalty for each present
        let forbiddenPresent = recipe.forbiddenComponents.intersection(detectedComponents)
        if !forbiddenPresent.isEmpty {
            let forbiddenScore = Double(forbiddenPresent.count) * forbiddenComponentPenalty
            score += forbiddenScore
            reasons.append("forbidden(\(forbiddenPresent.sorted().joined(separator: ",")))=\(Int(forbiddenScore))")
        }

        return (score, reasons.joined(separator: " "))
    }
}
