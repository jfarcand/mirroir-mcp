// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Budget constraints for autonomous app exploration (depth, screens, time, actions).
// ABOUTME: Prevents runaway exploration by enforcing configurable limits on DFS traversal.

import Foundation
import HelperLib

/// Budget constraints for autonomous app exploration.
/// Prevents runaway exploration by enforcing limits on depth, screen count,
/// elapsed time, and per-screen action count.
struct ExplorationBudget: Sendable {

    /// Maximum DFS depth before forcing backtrack.
    let maxDepth: Int

    /// Maximum distinct screens before stopping exploration.
    let maxScreens: Int

    /// Maximum wall-clock seconds before stopping exploration.
    let maxTimeSeconds: Int

    /// Maximum elements to try tapping on a single screen before moving on.
    let maxActionsPerScreen: Int

    /// Maximum scroll attempts per screen to reveal hidden content.
    let scrollLimit: Int

    /// Maximum scout taps on a single screen before forcing transition to dive phase.
    let maxScoutsPerScreen: Int

    /// Element text patterns that should never be tapped (destructive or dangerous actions).
    let skipPatterns: [String]

    /// Memberwise init with a default value for `maxScoutsPerScreen` to preserve backward
    /// compatibility at all existing call sites that predate the scout phase feature.
    init(
        maxDepth: Int,
        maxScreens: Int,
        maxTimeSeconds: Int,
        maxActionsPerScreen: Int,
        scrollLimit: Int,
        maxScoutsPerScreen: Int = 8,
        skipPatterns: [String]
    ) {
        self.maxDepth = maxDepth
        self.maxScreens = maxScreens
        self.maxTimeSeconds = maxTimeSeconds
        self.maxActionsPerScreen = maxActionsPerScreen
        self.scrollLimit = scrollLimit
        self.maxScoutsPerScreen = maxScoutsPerScreen
        self.skipPatterns = skipPatterns
    }

    /// Default budget suitable for most mobile app explorations.
    /// Reads limits from EnvConfig (settings.json / env vars) with sensible defaults.
    /// Includes built-in safety skip patterns for destructive, network, ad, and purchase actions.
    /// permissions.json `skipElements` can add patterns on top of these via `mergedWith(_:)`.
    static let `default` = ExplorationBudget(
        maxDepth: EnvConfig.explorationMaxDepth,
        maxScreens: EnvConfig.explorationMaxScreens,
        maxTimeSeconds: EnvConfig.explorationMaxTimeSeconds,
        maxActionsPerScreen: 5,
        scrollLimit: 3,
        maxScoutsPerScreen: 8,
        skipPatterns: builtInSkipPatterns
    )

    /// Safety-critical skip patterns that are always present regardless of permissions.json.
    /// Covers destructive actions, network toggles, ad/sponsored content, and purchase flows
    /// in English, French, Spanish, and German.
    static let builtInSkipPatterns: [String] = [
        // English destructive
        "delete", "sign out", "log out", "reset all", "erase all", "remove all",
        // French destructive
        "supprimer", "déconnexion", "déconnecter", "réinitialiser", "effacer",
        // Spanish destructive
        "eliminar", "cerrar sesión", "restablecer", "borrar",
        // Network toggles (multi-language)
        "airplane mode", "mode avion", "modo avión", "flugmodus",
        // Ad/sponsored content
        "sponsored", "promoted", "advertisement", "order now", "buy now", "install now",
        // Purchase actions (multi-language)
        "subscribe", "purchase", "s'abonner", "acheter",
    ]

    /// Return a new budget with additional skip patterns merged on top of built-in ones.
    func mergedWith(_ additionalPatterns: [String]) -> ExplorationBudget {
        guard !additionalPatterns.isEmpty else { return self }
        return ExplorationBudget(
            maxDepth: maxDepth,
            maxScreens: maxScreens,
            maxTimeSeconds: maxTimeSeconds,
            maxActionsPerScreen: maxActionsPerScreen,
            scrollLimit: scrollLimit,
            maxScoutsPerScreen: maxScoutsPerScreen,
            skipPatterns: skipPatterns + additionalPatterns
        )
    }

    /// Check if the exploration budget is exhausted based on current state.
    ///
    /// - Parameters:
    ///   - depth: Current DFS depth.
    ///   - screenCount: Number of distinct screens visited so far.
    ///   - elapsedSeconds: Wall-clock seconds since exploration started.
    /// - Returns: `true` if any budget limit has been reached.
    func isExhausted(depth: Int, screenCount: Int, elapsedSeconds: Int) -> Bool {
        depth >= maxDepth || screenCount >= maxScreens || elapsedSeconds >= maxTimeSeconds
    }

    /// Check if an element should be skipped based on its text.
    /// Case-insensitive containment check against skip patterns.
    func shouldSkipElement(text: String) -> Bool {
        let lowered = text.lowercased()
        return skipPatterns.contains { pattern in
            lowered.contains(pattern.lowercased())
        }
    }
}
