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
// ABOUTME: ExplorationStrategy for standard iOS mobile apps (Settings, social, productivity).
// ABOUTME: Classifies screens, ranks elements by navigation value, and determines backtrack actions.

import Foundation
import HelperLib

/// Exploration strategy tailored for standard iOS mobile apps.
/// Recognizes tab bars, list views, detail screens, and modals.
/// Prioritizes unvisited navigation targets and avoids destructive actions.
enum MobileAppStrategy: ExplorationStrategy {

    /// Text patterns indicating modal dismiss buttons.
    static let modalDismissPatterns: Set<String> = [
        "close", "done", "cancel", "dismiss", "ok",
    ]

    /// Minimum number of rows to classify a screen as a list.
    static let listRowThreshold = 4

    /// Y threshold below which elements are considered in the tab bar zone.
    /// Tab bars occupy roughly the bottom 12% of the screen.
    static let tabBarZoneFraction: Double = 0.88

    // MARK: - ExplorationStrategy

    static func classifyScreen(
        elements: [TapPoint], hints: [String]
    ) -> ScreenType {
        let hasBackChevron = hints.contains { $0.contains("Back navigation") }
        // Text-label clustering catches labeled bars; the detector's tab-bar
        // hint catches icon-only bars (Instagram) whose tabs carry no OCR text.
        let hasTabBar = detectTabBar(elements: elements)
            || hints.contains { $0.hasPrefix(NavigationHintDetector.tabBarHintPrefix) }

        // Modal detection: "Close", "Done", "Cancel" in top area
        let topElements = elements.filter { $0.tapY < LandmarkPicker.headerZoneRange.upperBound }
        let hasModalDismiss = topElements.contains { el in
            modalDismissPatterns.contains(el.text.lowercased())
        }

        if hasModalDismiss { return .modal }
        if hasTabBar && !hasBackChevron { return .tabRoot }

        // Count navigable rows (elements between status bar and tab bar)
        let navigable = ExplorationGuide.filterNavigableElements(elements)
        if navigable.count >= listRowThreshold && !hasBackChevron {
            return .settings
        }
        if navigable.count >= listRowThreshold && hasBackChevron {
            return .list
        }
        if hasBackChevron {
            return .detail
        }

        return .unknown
    }

    static func rankElements(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        visitedElements: Set<String>,
        depth: Int,
        screenType: ScreenType
    ) -> [TapPoint] {
        let navigable = ExplorationGuide.filterNavigableElements(elements)

        // Separate unvisited from visited
        let unvisited = navigable.filter { !visitedElements.contains($0.text) }
        let visited = navigable.filter { visitedElements.contains($0.text) }

        switch screenType {
        case .tabRoot:
            // Prioritize tab bar items (icons at bottom), then list content top-to-bottom
            let tabBarY = estimateTabBarY(elements: elements)
            let tabItems = unvisited.filter { $0.tapY >= tabBarY }
            let contentItems = unvisited.filter { $0.tapY < tabBarY }
            return tabItems + contentItems.sorted(by: { $0.tapY < $1.tapY }) + visited

        case .list, .settings:
            // Top-to-bottom order for list exploration
            return unvisited.sorted(by: { $0.tapY < $1.tapY }) + visited

        case .detail:
            // Detail screens: deprioritize (signal that backtracking is preferred)
            return unvisited.sorted(by: { $0.tapY < $1.tapY }) + visited

        case .modal:
            // Modal: show dismiss option prominently
            return unvisited.sorted(by: { $0.tapY < $1.tapY }) + visited

        case .unknown:
            return unvisited.sorted(by: { $0.tapY < $1.tapY }) + visited
        }
    }

    static func backtrackMethod(
        currentHints: [String], depth: Int
    ) -> BacktrackAction {
        let hasBackButton = currentHints.contains { $0.contains("Back navigation") }
        if hasBackButton {
            return .tapBack
        }
        if depth > 0 {
            return .tapBack
        }
        return .none
    }

    static func shouldSkip(elementText: String, budget: ExplorationBudget) -> Bool {
        budget.shouldSkipElement(text: elementText)
    }

    static func isTerminal(
        elements: [TapPoint],
        depth: Int,
        budget: ExplorationBudget,
        screenType: ScreenType
    ) -> Bool {
        // Budget exhausted
        if depth >= budget.maxDepth { return true }

        // Detail screen with no navigable children
        if screenType == .detail {
            let navigable = ExplorationGuide.filterNavigableElements(elements)
            if navigable.count <= 1 { return true }
        }

        return false
    }

    static func extractFingerprint(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon]
    ) -> String {
        StructuralFingerprint.compute(elements: elements, icons: icons)
    }

    // MARK: - Tab Bar Detection

    /// Detect if the screen has a tab bar based on icon/element clustering at the bottom.
    private static func detectTabBar(elements: [TapPoint]) -> Bool {
        guard let maxY = elements.map(\.tapY).max() else { return false }
        let tabBarY = maxY * tabBarZoneFraction

        // Count short labels near the bottom — tab bar items are typically 1-2 words
        let bottomLabels = elements.filter {
            $0.tapY >= tabBarY && $0.text.count <= LandmarkPicker.landmarkMaxLength
        }

        // Tab bars typically have 3-5 items
        return bottomLabels.count >= 3
    }

    /// Estimate the Y position where the tab bar starts.
    private static func estimateTabBarY(elements: [TapPoint]) -> Double {
        guard let maxY = elements.map(\.tapY).max() else { return 800 }
        return maxY * tabBarZoneFraction
    }
}
