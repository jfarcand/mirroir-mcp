// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Deduplication strategies for scroll-collected OCR elements.
// ABOUTME: Handles OCR variance across viewports via exact, fuzzy text, or coordinate proximity.

import Foundation
import HelperLib

/// Strategy for deduplicating OCR elements collected across multiple scroll viewports.
enum ScrollDedupStrategy: String {
    /// Current behavior: exact text match.
    case exact
    /// Fuzzy text: Levenshtein edit distance ≤ threshold.
    case levenshtein
    /// Coordinate-based: elements within N points of each other are merged.
    case proximity
}

/// Pure-transformation deduplication for scroll-collected OCR elements.
///
/// When scrolling through a page, the same on-screen element OCR'd at different scroll
/// positions can produce slightly different text (e.g. "O Activité" vs "D Activité").
/// This enum provides three strategies to collapse these duplicates.
enum ScrollDeduplicator {

    /// Deduplicate elements using the given strategy with configured thresholds.
    static func deduplicate(
        _ elements: [TapPoint],
        strategy: ScrollDedupStrategy,
        levenshteinMax: Int = EnvConfig.scrollDedupLevenshteinMax,
        proximityPt: Double = EnvConfig.scrollDedupProximityPt
    ) -> [TapPoint] {
        switch strategy {
        case .exact:
            return deduplicateExact(elements)
        case .levenshtein:
            return deduplicateLevenshtein(elements, maxDistance: levenshteinMax)
        case .proximity:
            return deduplicateProximity(elements, thresholdPt: proximityPt)
        }
    }

    /// Exact text match dedup: keeps the last occurrence of each text string.
    static func deduplicateExact(_ elements: [TapPoint]) -> [TapPoint] {
        var seen: [String: TapPoint] = [:]
        for element in elements {
            seen[element.text] = element
        }
        return Array(seen.values).sorted { $0.tapY < $1.tapY }
    }

    /// Fuzzy text dedup: groups elements whose text is within `maxDistance` edit distance.
    /// Keeps the element with the highest confidence from each group.
    static func deduplicateLevenshtein(
        _ elements: [TapPoint],
        maxDistance: Int
    ) -> [TapPoint] {
        guard !elements.isEmpty else { return [] }

        // Track which elements have been merged into a group
        var merged = [Bool](repeating: false, count: elements.count)
        var result: [TapPoint] = []

        for i in 0..<elements.count {
            if merged[i] { continue }

            var bestElement = elements[i]

            for j in (i + 1)..<elements.count {
                if merged[j] { continue }
                let dist = levenshteinDistance(bestElement.text, elements[j].text)
                if dist <= maxDistance {
                    merged[j] = true
                    if elements[j].confidence > bestElement.confidence {
                        bestElement = elements[j]
                    }
                }
            }
            result.append(bestElement)
        }

        return result.sorted { $0.tapY < $1.tapY }
    }

    /// Coordinate proximity dedup: groups elements within `thresholdPt` Euclidean distance.
    /// Keeps the element with the highest confidence from each group.
    static func deduplicateProximity(
        _ elements: [TapPoint],
        thresholdPt: Double
    ) -> [TapPoint] {
        guard !elements.isEmpty else { return [] }

        let thresholdSquared = thresholdPt * thresholdPt
        var merged = [Bool](repeating: false, count: elements.count)
        var result: [TapPoint] = []

        for i in 0..<elements.count {
            if merged[i] { continue }

            var bestElement = elements[i]

            for j in (i + 1)..<elements.count {
                if merged[j] { continue }
                let dx = bestElement.tapX - elements[j].tapX
                let dy = bestElement.tapY - elements[j].tapY
                let distSquared = dx * dx + dy * dy
                if distSquared <= thresholdSquared {
                    merged[j] = true
                    if elements[j].confidence > bestElement.confidence {
                        bestElement = elements[j]
                    }
                }
            }
            result.append(bestElement)
        }

        return result.sorted { $0.tapY < $1.tapY }
    }

    /// Classic dynamic programming Levenshtein distance (edit distance) between two strings.
    /// Returns the minimum number of single-character insertions, deletions, or substitutions
    /// needed to transform `a` into `b`.
    static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count

        if m == 0 { return n }
        if n == 0 { return m }

        // Use two rows instead of full matrix for O(min(m,n)) space
        var previousRow = [Int](0...n)
        var currentRow = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            currentRow[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                currentRow[j] = min(
                    previousRow[j] + 1,       // deletion
                    currentRow[j - 1] + 1,     // insertion
                    previousRow[j - 1] + cost  // substitution
                )
            }
            swap(&previousRow, &currentRow)
        }

        return previousRow[n]
    }
}
