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
// ABOUTME: Data model for component definitions loaded from COMPONENT.md files.
// ABOUTME: Extracted from ComponentSkillParser.swift to keep the parser focused on parsing.

import Foundation

/// Parsed component definition describing an iOS UI component's visual pattern,
/// match rules, interaction behavior, exploration policy, and element grouping rules.
struct ComponentDefinition: Sendable {
    let name: String
    let platform: String
    let description: String
    let visualPattern: [String]
    let matchRules: ComponentMatchRules
    let interaction: ComponentInteraction
    let exploration: ComponentExploration
    let grouping: ComponentGrouping
}

/// Chevron constraint mode for component matching.
/// Controls how chevron presence/absence affects matching scores.
enum ChevronMode: String, Sendable {
    /// Hard constraint: row must have a chevron or matching fails.
    case required
    /// Hard constraint: row must not have a chevron or matching fails.
    case forbidden
    /// Soft constraint: chevron presence gives a score bonus but absence does not fail.
    case preferred
}

/// Rules for matching OCR elements to a component type based on row properties.
struct ComponentMatchRules: Sendable {
    /// Whether the row must contain a chevron character. nil = don't care.
    /// Legacy field — prefer chevronMode for new definitions.
    let rowHasChevron: Bool?
    /// Chevron constraint mode. Takes precedence over rowHasChevron when set.
    let chevronMode: ChevronMode?
    /// Minimum number of OCR elements in the row.
    let minElements: Int
    /// Maximum number of OCR elements in the row.
    let maxElements: Int
    /// Maximum vertical span of the row in points.
    let maxRowHeightPt: Double
    /// Whether the row must contain a numeric value. nil = don't care.
    let hasNumericValue: Bool?
    /// Whether the row must contain long text (50+ chars). nil = don't care.
    let hasLongText: Bool?
    /// Whether the row must contain a dismiss button (X, ✕, ×). nil = don't care.
    let hasDismissButton: Bool?
    /// Screen zone where this component typically appears.
    let zone: ScreenZone
    /// Minimum average OCR confidence for the row. nil = don't constrain.
    let minConfidence: Double?
    /// When true, bare-digit elements (1-3 chars, all digits) are excluded from element count. nil = false.
    let excludeNumericOnly: Bool?
    /// Regex: at least one element's text must match. nil = don't constrain.
    let textPattern: String?
}

/// How a component responds to user interaction during exploration.
struct ComponentInteraction: Sendable {
    /// Whether tapping this component is expected to produce a result.
    let clickable: Bool
    /// Which element within the component to tap.
    let clickTarget: ClickTargetRule
    /// What happens when the component is tapped.
    let clickResult: ClickResult
    /// Whether the explorer should tap back after clicking.
    let backAfterClick: Bool
    /// How to derive the human-readable label from the component's elements.
    let labelRule: LabelRule
}

/// Rules for picking a display label from a component's OCR elements.
/// Prevents raw OCR artifacts ("icon", ">") from leaking into skill step names.
enum LabelRule: String, Sendable {
    /// Use the tap target's text (current default, backward-compatible).
    case tapTarget = "tap_target"
    /// Use the first non-decoration, non-icon element's text.
    case firstText = "first_text"
    /// Use the longest text element in the component.
    case longestText = "longest_text"
}

/// Rules for absorbing nearby OCR elements into a multi-row component.
struct ComponentGrouping: Sendable {
    /// Whether elements on the same row should be absorbed into this component.
    let absorbsSameRow: Bool
    /// Maximum Y-distance below the row to absorb additional elements.
    let absorbsBelowWithinPt: Double
    /// Condition for absorbing elements below.
    let absorbCondition: AbsorbCondition
    /// How to split matched rows into individual components.
    let splitMode: SplitMode
}

/// Controls whether a matched row produces one component or many.
/// Used for multi-item containers like tab bars where each item needs
/// its own tap target and exploration entry.
enum SplitMode: String, Sendable {
    /// One component per matched row (default).
    case none
    /// One component per non-decoration element in the row.
    case perItem = "per_item"
}

/// Screen zones used for component matching.
enum ScreenZone: String, Sendable {
    case navBar = "nav_bar"
    case content
    case tabBar = "tab_bar"
}

/// Rules for selecting which element to tap within a component.
enum ClickTargetRule: String, Sendable {
    case firstNavigation = "first_navigation_element"
    case firstText = "first_text"
    case firstDismissButton = "first_dismiss_button"
    case centered = "centered_element"
    case none
}

/// The expected result of tapping a component.
enum ClickResult: String, Sendable {
    case pushesScreen = "pushes_screen"
    case switchesContext = "switches_context"
    case opensModal = "opens_modal"
    case mutatesInPlace = "mutates_in_place"
    case dismisses
    case none

    /// Whether tapping this component leads to a new screen worth exploring.
    var isNavigational: Bool {
        switch self {
        case .pushesScreen, .switchesContext, .opensModal, .dismisses:
            return true
        case .mutatesInPlace, .none:
            return false
        }
    }

    /// Whether the explorer should backtrack after visiting.
    var requiresBacktrack: Bool {
        switch self {
        case .pushesScreen, .opensModal:
            return true
        case .switchesContext, .dismisses, .mutatesInPlace, .none:
            return false
        }
    }

    /// Initialize from raw string, supporting legacy "navigates" and "toggles" values.
    init(legacy rawValue: String) {
        switch rawValue {
        case "navigates": self = .pushesScreen
        case "toggles": self = .mutatesInPlace
        default: self = ClickResult(rawValue: rawValue) ?? .none
        }
    }
}

/// Exploration policy controlling how the BFS explorer treats this component.
/// Separate from interaction (UI truth) to avoid conflating "is tappable"
/// with "should be explored."
struct ComponentExploration: Sendable {
    /// Whether the explorer should visit this component.
    let explorable: Bool
    /// The exploration role determines priority ordering and backtrack behavior.
    let role: ExplorationRole
    /// Exploration priority within the role category.
    let priority: ExplorationPriority
}

/// Role a component plays in the exploration graph.
/// Determines frontier ordering: breadth before depth before action.
enum ExplorationRole: String, Sendable {
    /// Top-level navigation (tabs, sidebar). Explored first for app coverage.
    case breadthNavigation = "breadth_navigation"
    /// Drill-down navigation (rows, cards). Standard BFS ordering.
    case depthNavigation = "depth_navigation"
    /// Triggers behavior (search, buttons). Explored cautiously.
    case action
    /// Read-only element (headers, titles). Never explored.
    case info
}

/// Exploration priority within a role category.
enum ExplorationPriority: String, Sendable {
    case high
    case normal
    case low
}

/// Conditions for absorbing nearby elements into a multi-row component.
enum AbsorbCondition: String, Sendable {
    case any
    case infoOrDecorationOnly = "info_or_decoration_only"
    /// Absorb only rows that do NOT contain a chevron character.
    /// Used by table-row-disclosure to absorb sub-label rows (e.g. "12,4 km")
    /// while keeping adjacent chevron rows as separate navigable components.
    case noChevronRowsOnly = "no_chevron_rows_only"
}
