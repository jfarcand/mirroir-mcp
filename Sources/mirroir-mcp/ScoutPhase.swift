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
// ABOUTME: Scout-then-dive decision logic for DFS exploration.
// ABOUTME: Determines when to scout (tap+backtrack) vs dive (explore depth-first) on a screen.

import Foundation
import HelperLib

/// Traversal phase for a screen in the scout-then-dive workflow.
enum TraversalPhase: String, Sendable {
    /// Tap each element, observe result, immediately backtrack.
    case scout
    /// Explore confirmed navigation targets depth-first.
    case dive
    /// All elements scouted and dived.
    case exhausted
}

/// Result of scouting a single element.
enum ScoutResult: String, Sendable {
    /// Screen fingerprint changed after tap (element navigates).
    case navigated
    /// Screen fingerprint unchanged (element does not navigate).
    case noChange
}

/// Encapsulates scout/dive phase decision logic used by DFSExplorer.
/// Pure transformation: all static methods, no stored state.
enum ScoutPhase {

    /// Minimum navigation elements on a screen to justify scouting.
    static let minNavigationElementsForScout = 4

    /// Maximum depth at which scouting is allowed (0 = root, 1 = one level deep).
    static let maxScoutDepth = 1

    /// Screen types that benefit from scout-then-dive.
    /// Settings/list screens are excluded because chevron indicators (">" disclosure
    /// arrows) already identify navigation elements reliably via ElementClassifier.
    /// Scouting those screens doubles every tap for zero information gain.
    static let scoutableScreenTypes: Set<ScreenType> = [
        .tabRoot,
    ]

    // MARK: - Decision Logic

    /// Determine whether a screen should use scout-then-dive.
    ///
    /// Scouting is beneficial on broad screens (list/settings/tabRoot) at shallow depth
    /// with many potential navigation targets. It wastes budget on detail screens
    /// or deep subtrees where most elements are content, not navigation.
    ///
    /// - Parameters:
    ///   - screenType: Classification of the current screen.
    ///   - depth: Current DFS depth (0 = root).
    ///   - navigationCount: Number of elements classified as navigation.
    /// - Returns: `true` if the screen should be scouted before diving.
    static func shouldScout(
        screenType: ScreenType, depth: Int, navigationCount: Int
    ) -> Bool {
        guard scoutableScreenTypes.contains(screenType) else { return false }
        guard depth <= maxScoutDepth else { return false }
        guard navigationCount >= minNavigationElementsForScout else { return false }
        return true
    }

    /// Pick the next unscouted navigation element for the scout phase.
    ///
    /// Returns the first navigation-classified element whose text is not in `scouted`.
    /// Elements are returned in their original order (typically Y-sorted from OCR).
    ///
    /// - Parameters:
    ///   - classified: All classified elements on the current screen.
    ///   - scouted: Set of element texts already scouted.
    /// - Returns: The next element to scout, or nil if all navigation elements are scouted.
    static func nextScoutTarget(
        classified: [ClassifiedElement], scouted: Set<String>
    ) -> TapPoint? {
        classified
            .filter { $0.role == .navigation && !scouted.contains($0.point.text) }
            .first?.point
    }

    /// Rank elements for the dive phase using scout results.
    ///
    /// Priority order:
    /// 1. Elements that scouted as `.navigated` (confirmed navigation targets)
    /// 2. Unscouted elements (fallback, not yet tested)
    /// 3. Elements that scouted as `.noChange` are excluded (not navigation)
    ///
    /// - Parameters:
    ///   - scoutResults: Map of element text to scout result.
    ///   - classified: All classified elements on the current screen.
    /// - Returns: Elements ranked for dive-phase exploration.
    static func rankForDive(
        scoutResults: [String: ScoutResult],
        classified: [ClassifiedElement]
    ) -> [TapPoint] {
        let navigationElements = classified.filter { $0.role == .navigation }

        var navigated: [TapPoint] = []
        var unscouted: [TapPoint] = []

        for element in navigationElements {
            let text = element.point.text
            switch scoutResults[text] {
            case .navigated:
                navigated.append(element.point)
            case .noChange:
                // Exclude — scouting confirmed this does not navigate
                continue
            case nil:
                unscouted.append(element.point)
            }
        }

        return navigated + unscouted
    }
}
