// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Maps action type and arrivedVia pairs to markdown step text for SKILL.md.
// ABOUTME: Pure formatting function with no side effects.

import HelperLib

/// Formats an exploration action into a markdown step string.
/// Maps action types (tap, swipe, type, etc.) to their display format.
enum ActionStepFormatter {

    /// Text cleanup rules loaded from `text-cleanup.md` in the skills repo.
    /// Lazily initialized once on first use.
    static let cleanupRules = ComponentLoader.loadTextCleanupRules()

    /// Strip leading OCR noise characters (bullets, markers) from a label.
    /// Characters are defined in `text-cleanup.md`, not hardcoded.
    static func cleanLabel(
        _ text: String, stripPrefixes prefixes: [Character] = cleanupRules.stripPrefixes
    ) -> String {
        guard !prefixes.isEmpty else { return text }
        var result = text
        while let first = result.first, prefixes.contains(first) {
            result = String(result.dropFirst())
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// The items of one OCR line: `text` split on the segment separators
    /// `text-cleanup.md` declares, each cleaned of its leading markers, in
    /// reading order, empty segments dropped. OCR merges neighboring items
    /// into one line on one read and splits them on the next ("• Sommeil |
    /// Réveil" vs "Sommeil" and "Réveil"), so a label that must match a later
    /// read is taken from one segment. A line with no separator is its one
    /// cleaned segment.
    static func segments(
        of text: String, rules: ComponentLoader.TextCleanupRules = cleanupRules
    ) -> [String] {
        text.split(whereSeparator: { rules.segmentSeparators.contains($0) })
            .map {
                cleanLabel(String($0), stripPrefixes: rules.stripPrefixes)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    /// Check if a label should be excluded from skill output.
    /// Exclusions are defined in `text-cleanup.md`.
    static func isExcludedLabel(_ text: String) -> Bool {
        cleanupRules.excludeLabels.contains(text)
    }

    /// Resolve an arrivedVia label against screen elements.
    /// Attempts exact match, case-insensitive match, then containment match.
    /// Returns the best matching element's text for proper casing, or the original if no match.
    static func resolveLabel(arrivedVia: String, elements: [TapPoint]) -> String {
        // Exact match
        if elements.contains(where: { $0.text == arrivedVia }) {
            return arrivedVia
        }
        // Case-insensitive match
        let lowered = arrivedVia.lowercased()
        if let match = elements.first(where: { $0.text.lowercased() == lowered }) {
            return match.text
        }
        // Containment match (arrivedVia is substring of element or vice versa)
        if let match = elements.first(where: {
            $0.text.lowercased().contains(lowered) || lowered.contains($0.text.lowercased())
        }) {
            return match.text
        }
        // Graceful degradation: return original
        return arrivedVia
    }

    /// Format an action step from actionType and arrivedVia.
    /// Returns nil if no action should be emitted (e.g. first screen with no arrivedVia).
    ///
    /// Most actions require `arrivedVia` to specify the target element or value.
    /// Self-sufficient actions like `press_home` emit a step without arrivedVia.
    static func format(actionType: String?, arrivedVia: String?) -> String? {
        guard let actionType = actionType, !actionType.isEmpty else {
            // No action type: only emit if arrivedVia is present (default to tap)
            guard let rawVia = arrivedVia, !rawVia.isEmpty else { return nil }
            let via = cleanLabel(rawVia)
            guard !via.isEmpty else { return nil }
            return "Tap \"\(via)\""
        }

        // Self-sufficient actions that produce a step without arrivedVia
        switch actionType {
        case "press_home":
            return "Press Home"
        default:
            break
        }

        // All remaining actions require arrivedVia
        guard let rawVia = arrivedVia, !rawVia.isEmpty else { return nil }
        let arrivedVia = cleanLabel(rawVia)
        guard !arrivedVia.isEmpty else { return nil }

        switch actionType {
        case "tap":
            return "Tap \"\(arrivedVia)\""
        case "swipe":
            return "swipe: \"\(arrivedVia)\""
        case "type":
            return "Type \"\(arrivedVia)\""
        case "press_key":
            return "Press **\(arrivedVia)**"
        case "scroll_to":
            return "Scroll until \"\(arrivedVia)\" is visible"
        case "long_press":
            return "long_press: \"\(arrivedVia)\""
        case "remember":
            return "Remember: \(arrivedVia)"
        case "screenshot":
            return "Screenshot: \"\(arrivedVia)\""
        case "assert_visible":
            return "Verify \"\(arrivedVia)\" is visible"
        case "assert_not_visible":
            return "Verify \"\(arrivedVia)\" is not visible"
        case "open_url":
            return "Open URL: \(arrivedVia)"
        default:
            return "Tap \"\(arrivedVia)\""
        }
    }
}
