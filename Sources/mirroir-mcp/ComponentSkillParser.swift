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
// ABOUTME: Parses COMPONENT.md files (YAML front matter + markdown sections) into ComponentDefinition.
// ABOUTME: Enables user-defined UI component patterns for BFS exploration element grouping.

import Foundation


/// Parses COMPONENT.md files: YAML front matter + markdown sections with key-value match rules.
/// Follows the same pattern as SkillMdParser for front matter extraction.
enum ComponentSkillParser {

    // MARK: - Known Keys (for validation)

    /// Valid keys per section. Used by `parseValidated` to reject typos.
    static let knownKeys: [String: Set<String>] = [
        "Match Rules": [
            "row_has_chevron", "chevron_mode", "min_elements", "max_elements",
            "max_row_height_pt", "has_numeric_value", "has_long_text",
            "has_dismiss_button", "zone", "min_confidence", "exclude_numeric_only",
            "text_pattern",
        ],
        "Interaction": [
            "clickable", "click_target", "click_result", "back_after_click", "label_rule",
        ],
        "Exploration": ["explorable", "role", "priority"],
        "Grouping": [
            "absorbs_same_row", "absorbs_below_within_pt", "absorb_condition", "split_mode",
        ],
    ]

    /// Parse with validation. Returns nil and logs an error if the definition
    /// contains unknown keys (typos like "has_dismiss_icon") OR invalid enum
    /// values (e.g. priority: critical when only low/normal/high exist).
    /// Strict validation surfaces taxonomy drift in pattern files at load
    /// time instead of letting it silently degrade to defaults at runtime.
    static func parseValidated(content: String, fallbackName: String) -> ComponentDefinition? {
        let body = extractBody(content: content)
        let sections = extractSections(from: body)
        let name = extractValue(from: extractFrontMatter(content: content), key: "name")
            ?? fallbackName

        for (section, allowed) in knownKeys {
            guard let text = sections[section] else { continue }
            let unknown = Set(extractKeyValues(from: text).keys).subtracting(allowed)
            if !unknown.isEmpty {
                DebugLog.log("components",
                    "REJECTED \"\(name)\": unknown keys in \(section): " +
                    "\(unknown.sorted().joined(separator: ", "))")
                return nil
            }
        }

        if let problem = invalidEnumValue(in: sections) {
            DebugLog.log("components",
                "REJECTED \"\(name)\": invalid value '\(problem.value)' for "
                + "\(problem.section).\(problem.key)")
            return nil
        }

        return parse(content: content, fallbackName: fallbackName)
    }

    /// Returns the first invalid enum-typed key found in the parsed sections,
    /// or nil if every typed value parses cleanly. Used by `parseValidated`
    /// to fail-loud on taxonomy drift.
    private static func invalidEnumValue(
        in sections: [String: String]
    ) -> (section: String, key: String, value: String)? {
        let checks: [(section: String, key: String, validator: @Sendable (String) -> Bool)] = [
            ("Match Rules", "zone", { ScreenZone(rawValue: $0) != nil }),
            ("Match Rules", "chevron_mode", { ChevronMode(rawValue: $0) != nil }),
            ("Interaction", "click_target", { ClickTargetRule(rawValue: $0) != nil }),
            ("Interaction", "click_result", { value in
                // ClickResult accepts the new enum values plus legacy aliases.
                ClickResult(rawValue: value) != nil
                    || value == "navigates" || value == "toggles"
            }),
            ("Interaction", "label_rule", { LabelRule(rawValue: $0) != nil }),
            ("Exploration", "role", { ExplorationRole(rawValue: $0) != nil }),
            ("Exploration", "priority", { ExplorationPriority(rawValue: $0) != nil }),
            ("Grouping", "absorb_condition", { AbsorbCondition(rawValue: $0) != nil }),
            ("Grouping", "split_mode", { SplitMode(rawValue: $0) != nil }),
        ]
        for check in checks {
            guard let text = sections[check.section] else { continue }
            let kv = extractKeyValues(from: text)
            guard let value = kv[check.key] else { continue }
            if !check.validator(value) {
                return (check.section, check.key, value)
            }
        }
        return nil
    }

    /// Parse a COMPONENT.md file's content into a ComponentDefinition.
    /// Does NOT validate keys — use `parseValidated` for strict loading.
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
        let roleStr = kv["role"] ?? "depth_navigation"
        let priorityStr = kv["priority"] ?? "normal"
        if kv["role"] != nil && ExplorationRole(rawValue: roleStr) == nil {
            DebugLog.log("components",
                "WARNING: invalid exploration role '\(roleStr)' — defaulting to depth_navigation")
        }
        if kv["priority"] != nil && ExplorationPriority(rawValue: priorityStr) == nil {
            DebugLog.log("components",
                "WARNING: invalid exploration priority '\(priorityStr)' — defaulting to normal")
        }
        return ComponentExploration(
            explorable: parseBool(kv["explorable"]) ?? interaction.clickable,
            role: ExplorationRole(rawValue: roleStr) ?? .depthNavigation,
            priority: ExplorationPriority(rawValue: priorityStr) ?? .normal
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
