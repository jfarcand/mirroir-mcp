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
// ABOUTME: ExplorationStrategy for social media apps (Reddit, Instagram, TikTok).
// ABOUTME: Delegates to MobileAppStrategy for base behavior, adds social-specific skip patterns and depth caps.

import Foundation
import HelperLib

/// Exploration strategy tailored for social media apps.
/// Delegates base behavior to MobileAppStrategy and adds social-specific logic:
/// skipping ad/engagement content, capping profile depth, and filtering feed noise.
enum SocialAppStrategy: ExplorationStrategy {

    /// Social-specific element text patterns to skip during exploration.
    /// These are engagement/interaction elements that don't lead to useful navigation paths.
    static let socialSkipPatterns: Set<String> = [
        "sponsored", "promoted", "story", "stories",
        "follow", "unfollow", "share", "repost",
        "upvote", "downvote",
    ]

    /// Maximum depth for detail screens (profile pages, post threads).
    /// Social apps tend to have deep but repetitive content chains.
    static let profileDepthCap = 3

    // MARK: - ExplorationStrategy

    static func classifyScreen(
        elements: [TapPoint], hints: [String]
    ) -> ScreenType {
        MobileAppStrategy.classifyScreen(elements: elements, hints: hints)
    }

    static func rankElements(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        visitedElements: Set<String>,
        depth: Int,
        screenType: ScreenType
    ) -> [TapPoint] {
        let baseRanked = MobileAppStrategy.rankElements(
            elements: elements, icons: icons,
            visitedElements: visitedElements, depth: depth, screenType: screenType
        )
        // Filter out social skip pattern elements from results
        return baseRanked.filter { element in
            !isSocialSkipElement(element.text)
        }
    }

    static func backtrackMethod(
        currentHints: [String], depth: Int
    ) -> BacktrackAction {
        MobileAppStrategy.backtrackMethod(currentHints: currentHints, depth: depth)
    }

    static func shouldSkip(elementText: String, budget: ExplorationBudget) -> Bool {
        if MobileAppStrategy.shouldSkip(elementText: elementText, budget: budget) {
            return true
        }
        return isSocialSkipElement(elementText)
    }

    static func isTerminal(
        elements: [TapPoint],
        depth: Int,
        budget: ExplorationBudget,
        screenType: ScreenType
    ) -> Bool {
        // Delegate base terminal check
        if MobileAppStrategy.isTerminal(
            elements: elements, depth: depth, budget: budget, screenType: screenType
        ) {
            return true
        }
        // Cap depth on detail screens (profile pages, post threads)
        if screenType == .detail && depth >= profileDepthCap {
            return true
        }
        return false
    }

    static func extractFingerprint(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon]
    ) -> String {
        MobileAppStrategy.extractFingerprint(elements: elements, icons: icons)
    }

    // MARK: - Private

    /// Check if element text matches a social skip pattern (case-insensitive).
    private static func isSocialSkipElement(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return socialSkipPatterns.contains { pattern in
            lowered.contains(pattern)
        }
    }
}
