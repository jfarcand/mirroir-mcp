// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Parses COMPONENT.md files (YAML front matter + markdown sections) into ComponentDefinition.
// ABOUTME: Enables user-defined UI component patterns for BFS exploration element grouping.

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
}

/// Parses COMPONENT.md files: YAML front matter + markdown sections with key-value match rules.
/// Follows the same pattern as SkillMdParser for front matter extraction.
enum ComponentSkillParser {

    /// Parse a COMPONENT.md file's content into a ComponentDefinition.
    ///
    /// - Parameters:
    ///   - content: The raw markdown string content of the file.
    ///   - fallbackName: Name to use if none is found in front matter.
    /// - Returns: A parsed ComponentDefinition.
    static func parse(content: String, fallbackName: String) -> ComponentDefinition {
        let frontMatter = extractFrontMatter(content: content)
        let name = extractValue(from: frontMatter, key: "name") ?? fallbackName
        let platform = extractValue(from: frontMatter, key: "platform") ?? "ios"

        let body = extractBody(content: content)
        let sections = extractSections(from: body)

        let description = extractFirstParagraph(from: sections["Description"] ?? "")
        let visualPattern = extractBulletList(from: sections["Visual Pattern"] ?? "")
        let matchRules = parseMatchRules(sections["Match Rules"] ?? "")
        let interaction = parseInteraction(sections["Interaction"] ?? "")
        let exploration = parseExploration(sections["Exploration"] ?? "", interaction: interaction)
        let grouping = parseGrouping(sections["Grouping"] ?? "")

        return ComponentDefinition(
            name: name,
            platform: platform,
            description: description,
            visualPattern: visualPattern,
            matchRules: matchRules,
            interaction: interaction,
            exploration: exploration,
            grouping: grouping
        )
    }

    // MARK: - Front Matter

    /// Extract the raw front matter string between `---` delimiters.
    private static func extractFrontMatter(content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var foundFirst = false
        var fmLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !foundFirst {
                    foundFirst = true
                    continue
                } else {
                    break
                }
            }
            if foundFirst {
                fmLines.append(line)
            }
        }

        return foundFirst ? fmLines.joined(separator: "\n") : ""
    }

    /// Extract everything after the closing `---` delimiter.
    private static func extractBody(content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var foundFirst = false
        var bodyStart: Int?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !foundFirst {
                    foundFirst = true
                } else {
                    bodyStart = index + 1
                    break
                }
            }
        }

        guard let start = bodyStart, start < lines.count else {
            return foundFirst ? "" : content
        }
        return Array(lines[start...]).joined(separator: "\n")
    }

    /// Extract named sections from markdown body (keyed by heading text without `##`).
    private static func extractSections(from body: String) -> [String: String] {
        let lines = body.components(separatedBy: .newlines)
        var sections: [String: String] = [:]
        var currentKey: String?
        var currentLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                // Save previous section
                if let key = currentKey {
                    sections[key] = currentLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentKey = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentLines = []
            } else if currentKey != nil {
                currentLines.append(line)
            }
        }

        // Save last section
        if let key = currentKey {
            sections[key] = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return sections
    }

    // MARK: - Section Parsers

    /// Parse key-value lines from a Match Rules section.
    private static func parseMatchRules(_ text: String) -> ComponentMatchRules {
        let kv = extractKeyValues(from: text)
        let chevronMode = kv["chevron_mode"].flatMap { ChevronMode(rawValue: $0) }
        return ComponentMatchRules(
            rowHasChevron: parseBool(kv["row_has_chevron"]),
            chevronMode: chevronMode,
            minElements: parseInt(kv["min_elements"]) ?? 1,
            maxElements: parseInt(kv["max_elements"]) ?? 10,
            maxRowHeightPt: parseDouble(kv["max_row_height_pt"]) ?? 100,
            hasNumericValue: parseBool(kv["has_numeric_value"]),
            hasLongText: parseBool(kv["has_long_text"]),
            hasDismissButton: parseBool(kv["has_dismiss_button"]),
            zone: ScreenZone(rawValue: kv["zone"] ?? "content") ?? .content,
            minConfidence: parseDouble(kv["min_confidence"]),
            excludeNumericOnly: parseBool(kv["exclude_numeric_only"]),
            textPattern: kv["text_pattern"]
        )
    }

    /// Parse key-value lines from an Interaction section.
    private static func parseInteraction(_ text: String) -> ComponentInteraction {
        let kv = extractKeyValues(from: text)
        return ComponentInteraction(
            clickable: parseBool(kv["clickable"]) ?? false,
            clickTarget: ClickTargetRule(rawValue: kv["click_target"] ?? "none") ?? .none,
            clickResult: ClickResult(legacy: kv["click_result"] ?? "none"),
            backAfterClick: parseBool(kv["back_after_click"]) ?? false,
            labelRule: LabelRule(rawValue: kv["label_rule"] ?? "tap_target") ?? .tapTarget
        )
    }

    /// Parse key-value lines from a Grouping section.
    private static func parseGrouping(_ text: String) -> ComponentGrouping {
        let kv = extractKeyValues(from: text)
        return ComponentGrouping(
            absorbsSameRow: parseBool(kv["absorbs_same_row"]) ?? true,
            absorbsBelowWithinPt: parseDouble(kv["absorbs_below_within_pt"]) ?? 0,
            absorbCondition: AbsorbCondition(rawValue: kv["absorb_condition"] ?? "any") ?? .any,
            splitMode: SplitMode(rawValue: kv["split_mode"] ?? "none") ?? .none
        )
    }

    /// Parse key-value lines from an Exploration section.
    /// Defaults when section is absent: explorable = clickable, role = depth_navigation, priority = normal.
    private static func parseExploration(
        _ text: String, interaction: ComponentInteraction
    ) -> ComponentExploration {
        let kv = extractKeyValues(from: text)
        return ComponentExploration(
            explorable: parseBool(kv["explorable"]) ?? interaction.clickable,
            role: ExplorationRole(rawValue: kv["role"] ?? "depth_navigation") ?? .depthNavigation,
            priority: ExplorationPriority(rawValue: kv["priority"] ?? "normal") ?? .normal
        )
    }

    // MARK: - Value Extraction Helpers

    /// Extract `key: value` pairs from a section's text. Supports YAML-like lines prefixed with `-`.
    private static func extractKeyValues(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            var stripped = line.trimmingCharacters(in: .whitespaces)
            // Allow both `- key: value` and `key: value` formats
            if stripped.hasPrefix("- ") {
                stripped = String(stripped.dropFirst(2))
            }
            guard let colonIndex = stripped.firstIndex(of: ":") else { continue }
            let key = String(stripped[stripped.startIndex..<colonIndex])
                .trimmingCharacters(in: .whitespaces)
            let value = String(stripped[stripped.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private static func extractValue(from frontMatter: String, key: String) -> String? {
        let kv = extractKeyValues(from: frontMatter)
        let value = kv[key]
        return (value?.isEmpty ?? true) ? nil : value
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: return nil
        }
    }

    private static func parseInt(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value)
    }

    private static func parseDouble(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value)
    }

    /// Extract bullet points from a markdown list section.
    private static func extractBulletList(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    /// Extract the first paragraph (before a blank line or heading).
    private static func extractFirstParagraph(from text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if !lines.isEmpty { break }
                continue
            }
            lines.append(trimmed)
        }
        return lines.joined(separator: " ")
    }
}
