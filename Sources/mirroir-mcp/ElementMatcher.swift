// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Fuzzy text matching against OCR-detected screen elements.
// ABOUTME: Used by the test runner to find tap targets and assert element visibility.

import Foundation
import HelperLib

/// Matches a text label against OCR-detected TapPoint elements.
/// Match priority: exact → case-insensitive → diacritic-insensitive → substring (case-insensitive).
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
        case diacriticInsensitive = "diacritic-insensitive"
        case substring = "substring"
    }

    /// Find the best matching element for the given label.
    /// Returns nil if no match is found. Among elements matched by the same
    /// strategy, the one nearest `anchor` wins when given (a compiled tap passes
    /// its recorded spot, so a tab label is not mistaken for a page title with
    /// the same text); otherwise the first one in reading order.
    static func findMatch(label: String, in elements: [TapPoint],
                          nearestTo anchor: (x: Double, y: Double)? = nil) -> MatchResult? {
        guard !label.isEmpty, !elements.isEmpty else { return nil }

        let lowerLabel = label.lowercased()
        let foldedLabel = label.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                         locale: nil)
        // Reverse substring requires the element text to cover at least half the
        // label length (minimum 3 characters) to avoid false matches on short OCR fragments.
        let minReverseLength = max(3, lowerLabel.count / 2)

        // Priority order: exact → case-insensitive → diacritic-insensitive ("Résumé"
        // matches "Resume") → substring (label contained in element text) → reverse
        // substring (element text contained in label).
        let tiers: [(MatchStrategy, (TapPoint) -> Bool)] = [
            (.exact, { $0.text == label }),
            (.caseInsensitive, { $0.text.lowercased() == lowerLabel }),
            (.diacriticInsensitive, {
                $0.text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                locale: nil) == foldedLabel
            }),
            (.substring, { $0.text.lowercased().contains(lowerLabel) }),
            (.substring, {
                let lower = $0.text.lowercased()
                return lower.count >= minReverseLength && lowerLabel.contains(lower)
            }),
        ]
        for (strategy, matches) in tiers {
            let candidates = elements.filter(matches)
            guard let first = candidates.first else { continue }
            guard let anchor else { return MatchResult(element: first, strategy: strategy) }
            let nearest = candidates.min { lhs, rhs in
                distanceSquared(lhs, anchor) < distanceSquared(rhs, anchor)
            } ?? first
            return MatchResult(element: nearest, strategy: strategy)
        }
        return nil
    }

    private static func distanceSquared(_ element: TapPoint, _ anchor: (x: Double, y: Double)) -> Double {
        let dx = element.tapX - anchor.x
        let dy = element.tapY - anchor.y
        return dx * dx + dy * dy
    }

    /// Check whether a label is visible on screen (any match strategy).
    static func isVisible(label: String, in elements: [TapPoint]) -> Bool {
        findMatch(label: label, in: elements) != nil
    }
}
