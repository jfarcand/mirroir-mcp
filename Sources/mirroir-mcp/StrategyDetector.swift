// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Auto-detects the appropriate exploration strategy based on target type, app name, and screen recipes.
// ABOUTME: Returns a StrategyChoice enum value used by GenerateSkillTools and ExplorationSession.

import Foundation

/// The detected exploration strategy for an app.
enum StrategyChoice: String, Sendable {
    case mobile
    case social
    case desktop
}

/// Detects the appropriate exploration strategy for a target/app combination.
/// Detection order: explicit override → target type → app name → mobile default.
enum StrategyDetector {

    /// Known social media app names (case-insensitive matching).
    static let socialAppNames: Set<String> = [
        "reddit", "instagram", "facebook", "twitter", "x", "tiktok", "snapchat",
    ]

    /// Detect the exploration strategy based on available context.
    ///
    /// - Parameters:
    ///   - targetType: The target type string (e.g. "iphone-mirroring", "macos-app").
    ///   - appName: The display name of the app being explored.
    ///   - explicitStrategy: Optional explicit override from the user.
    /// - Returns: The detected strategy choice.
    static func detect(
        targetType: String,
        appName: String,
        explicitStrategy: String? = nil
    ) -> StrategyChoice {
        // Explicit override takes priority
        if let explicit = explicitStrategy {
            if let choice = StrategyChoice(rawValue: explicit) {
                return choice
            }
        }

        // Target profile drives the baseline — no string sniffing.
        let profile = TargetKind.profile(for: targetType)

        // App name matching for social apps overrides only mobile defaults.
        if profile.defaultStrategy == .mobile
            && socialAppNames.contains(appName.lowercased()) {
            return .social
        }

        return profile.defaultStrategy
    }

    /// Refine strategy using detected screen components and loaded recipes.
    ///
    /// Called after the first screen's components are detected. If a recipe matches,
    /// the strategy may be updated (e.g. detecting infinite-scroll components switches
    /// from mobile to social). Explicit user overrides are never changed.
    ///
    /// - Parameters:
    ///   - current: The current strategy from initial detection.
    ///   - detectedComponents: Component kind names found on the first screen.
    ///   - recipes: Loaded recipe definitions.
    ///   - explicitStrategy: The user's explicit override, if any.
    /// - Returns: A tuple of (possibly refined strategy, matched recipe or nil).
    static func refineWithRecipe(
        current: StrategyChoice,
        detectedComponents: Set<String>,
        recipes: [ScreenRecipe],
        explicitStrategy: String? = nil
    ) -> (StrategyChoice, RecipeMatch?) {
        // Never override explicit user choice
        if explicitStrategy != nil {
            return (current, nil)
        }

        guard let match = RecipeMatcher.bestMatch(
            detectedComponents: detectedComponents,
            recipes: recipes
        ) else {
            return (current, nil)
        }

        let refined = RecipeMatcher.strategyFromRecipe(match.recipe, fallback: current)
        return (refined, match)
    }
}
