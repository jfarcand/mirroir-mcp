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

    /// Maximum scroll attempts per screen to reveal hidden content during exploration.
    let scrollLimit: Int

    /// Maximum scroll attempts during calibration to discover below-fold content.
    /// Separate from scrollLimit because calibration needs more scrolls to map the
    /// full page, while exploration scrolls are just for finding a specific element.
    let calibrationScrollLimit: Int

    /// Maximum scout taps on a single screen before forcing transition to dive phase.
    let maxScoutsPerScreen: Int

    /// Element text patterns that should never be tapped (destructive or dangerous actions).
    /// Plain entries match as case-insensitive substrings. Entries wrapped in
    /// slashes (`/et \d+ autres/`) compile as case-insensitive regular
    /// expressions — needed where a literal substring would over-block (a bare
    /// "autres" would also skip an "Autres" nav label) or where the text varies
    /// ("et 64 autres" for any count). An entry whose regex fails to compile
    /// falls back to literal substring matching of the whole entry.
    let skipPatterns: [String]

    /// Regex entries from `skipPatterns`, compiled once at init.
    private let skipRegexes: [NSRegularExpression]
    /// Substring entries from `skipPatterns`, lowercased once at init.
    private let skipSubstrings: [String]

    /// Memberwise init with a default value for `maxScoutsPerScreen` to preserve backward
    /// compatibility at all existing call sites that predate the scout phase feature.
    init(
        maxDepth: Int,
        maxScreens: Int,
        maxTimeSeconds: Int,
        maxActionsPerScreen: Int,
        scrollLimit: Int,
        calibrationScrollLimit: Int = 15,
        maxScoutsPerScreen: Int = 8,
        skipPatterns: [String]
    ) {
        self.maxDepth = maxDepth
        self.maxScreens = maxScreens
        self.maxTimeSeconds = maxTimeSeconds
        self.maxActionsPerScreen = maxActionsPerScreen
        self.scrollLimit = scrollLimit
        self.calibrationScrollLimit = calibrationScrollLimit
        self.maxScoutsPerScreen = maxScoutsPerScreen
        self.skipPatterns = skipPatterns

        var regexes: [NSRegularExpression] = []
        var substrings: [String] = []
        for pattern in skipPatterns {
            if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/"),
               let regex = try? NSRegularExpression(
                   pattern: String(pattern.dropFirst().dropLast()),
                   options: [.caseInsensitive]) {
                regexes.append(regex)
            } else {
                substrings.append(pattern.lowercased())
            }
        }
        self.skipRegexes = regexes
        self.skipSubstrings = substrings
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
        calibrationScrollLimit: 15,
        maxScoutsPerScreen: 8,
        skipPatterns: builtInSkipPatterns
    )

    /// Safety-critical skip patterns that are always present regardless of permissions.json.
    /// English only — localized patterns belong in component skill definitions, not in code.
    static let builtInSkipPatterns: [String] = [
        // Destructive actions
        "delete", "sign out", "log out", "reset all", "erase all", "remove all",
        // Network toggles
        "airplane mode",
        // Ad/sponsored content
        "sponsored", "promoted", "advertisement",
        // Purchase actions
        "subscribe", "purchase", "order now", "buy now", "install now",
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
            calibrationScrollLimit: calibrationScrollLimit,
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
    /// Substring entries match by case-insensitive containment; `/.../` entries
    /// match as case-insensitive regular expressions (see `skipPatterns`).
    func shouldSkipElement(text: String) -> Bool {
        let lowered = text.lowercased()
        if skipSubstrings.contains(where: { lowered.contains($0) }) {
            return true
        }
        let range = NSRange(text.startIndex..., in: text)
        return skipRegexes.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}
