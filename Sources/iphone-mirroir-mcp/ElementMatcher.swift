// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Fuzzy text matching against OCR-detected screen elements.
// ABOUTME: Used by the test runner to find tap targets and assert element visibility.

import Foundation
import HelperLib

/// Matches a text label against OCR-detected TapPoint elements.
/// Match priority: exact → case-insensitive → substring (case-insensitive).
enum ElementMatcher {

    /// Result of a match attempt, including which strategy succeeded.
    struct MatchResult {
        let element: TapPoint
        let strategy: MatchStrategy
    }

    /// How the match was found.
    enum MatchStrategy: String {
        case exact = "exact"
        case caseInsensitive = "case-insensitive"
        case substring = "substring"
    }

    /// Find the best matching element for the given label.
    /// Returns nil if no match is found.
    static func findMatch(label: String, in elements: [TapPoint]) -> MatchResult? {
        guard !label.isEmpty, !elements.isEmpty else { return nil }

        // Priority 1: Exact match
        if let element = elements.first(where: { $0.text == label }) {
            return MatchResult(element: element, strategy: .exact)
        }

        let lowerLabel = label.lowercased()

        // Priority 2: Case-insensitive match
        if let element = elements.first(where: { $0.text.lowercased() == lowerLabel }) {
            return MatchResult(element: element, strategy: .caseInsensitive)
        }

        // Priority 3: Substring match (case-insensitive) — label contained in element text
        if let element = elements.first(where: {
            $0.text.lowercased().contains(lowerLabel)
        }) {
            return MatchResult(element: element, strategy: .substring)
        }

        // Priority 4: Reverse substring — element text contained in label
        if let element = elements.first(where: {
            lowerLabel.contains($0.text.lowercased()) && !$0.text.isEmpty
        }) {
            return MatchResult(element: element, strategy: .substring)
        }

        return nil
    }

    /// Check whether a label is visible on screen (any match strategy).
    static func isVisible(label: String, in elements: [TapPoint]) -> Bool {
        findMatch(label: label, in: elements) != nil
    }
}
