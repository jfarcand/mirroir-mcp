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
// ABOUTME: ExplorationStrategy for generic macOS desktop windows.
// ABOUTME: Classifies screens without tab bar heuristics, prioritizes sidebar items, uses Cmd+[ for backtracking.

import Foundation
import HelperLib

/// Exploration strategy tailored for generic macOS desktop application windows.
/// Unlike mobile apps, desktop windows don't have tab bars. Instead, they typically
/// have sidebars, menu-like layouts, dialogs, and content areas.
enum DesktopAppStrategy: ExplorationStrategy {

    /// X threshold below which elements are considered in a sidebar.
    static let sidebarMaxX: Double = 200

    /// Minimum number of sidebar-positioned elements to classify as settings/sidebar layout.
    static let sidebarMinElements = 3

    /// Minimum number of content elements to classify as a list.
    static let listMinElements = 4

    /// Text patterns for modal dismiss buttons.
    static let modalDismissPatterns: Set<String> = [
        "ok", "cancel", "close", "done", "dismiss",
    ]

    /// Desktop-specific destructive action patterns to skip.
    static let desktopSkipPatterns: [String] = [
        "Quit", "Force Quit", "Format", "Uninstall",
    ]

    // MARK: - ExplorationStrategy

    static func classifyScreen(
        elements: [TapPoint], hints: [String]
    ) -> ScreenType {
        let navigable = ExplorationGuide.filterNavigableElements(elements)

        // Dialog detection: modal dismiss buttons + few elements
        let hasModalDismiss = navigable.contains { el in
            modalDismissPatterns.contains(el.text.lowercased())
        }
        if hasModalDismiss && navigable.count <= 8 {
            return .modal
        }

        // Sidebar detection: 3+ elements with low X coordinate
        let sidebarElements = navigable.filter { $0.tapX < sidebarMaxX }
        if sidebarElements.count >= sidebarMinElements {
            return .settings
        }

        // Content-rich: 4+ navigable elements → list
        if navigable.count >= listMinElements {
            return .list
        }

        // Sparse content → detail
        if !navigable.isEmpty {
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
        let unvisited = navigable.filter { !visitedElements.contains($0.text) }
        let visited = navigable.filter { visitedElements.contains($0.text) }

        // Sidebar items first (low X), then content items, both sorted by Y
        let sidebarItems = unvisited.filter { $0.tapX < sidebarMaxX }
            .sorted(by: { $0.tapY < $1.tapY })
        let contentItems = unvisited.filter { $0.tapX >= sidebarMaxX }
            .sorted(by: { $0.tapY < $1.tapY })

        return sidebarItems + contentItems + visited
    }

    static func backtrackMethod(
        currentHints: [String], depth: Int
    ) -> BacktrackAction {
        // Desktop apps: Cmd+[ as universal back navigation
        if depth > 0 {
            return .pressBack
        }
        return .none
    }

    static func shouldSkip(elementText: String, budget: ExplorationBudget) -> Bool {
        if budget.shouldSkipElement(text: elementText) {
            return true
        }
        let lowered = elementText.lowercased()
        return desktopSkipPatterns.contains { pattern in
            lowered.contains(pattern.lowercased())
        }
    }

    static func isTerminal(
        elements: [TapPoint],
        depth: Int,
        budget: ExplorationBudget,
        screenType: ScreenType
    ) -> Bool {
        // Budget depth exhausted
        if depth >= budget.maxDepth { return true }

        // Modal screens are terminal (dismiss and move on)
        if screenType == .modal { return true }

        // Sparse detail screens with no navigable children
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
}
