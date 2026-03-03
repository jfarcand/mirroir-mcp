// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Merges new viewport elements into an accumulated page using scroll offset deduplication.
// ABOUTME: Elements in overlap zones are deduped by text; non-overlapping elements get page-absolute Y.

import Foundation
import HelperLib

/// Merges OCR elements from scrolled viewports into an accumulated list
/// with page-absolute coordinates. Uses scroll offset to identify overlap
/// zones and deduplicates elements that appear in both viewports.
enum OverlapDeduplicator {

    /// Tolerance in points for matching overlapping elements by Y position.
    static let overlapYTolerance: Double = 20.0

    /// Merge new viewport elements into the accumulated element list.
    ///
    /// Elements in the overlap zone (determined by scroll offset) are deduplicated
    /// by text. Non-overlapping elements are appended with page-absolute Y coordinates.
    ///
    /// - Parameters:
    ///   - accumulated: Previously collected elements with page-absolute Y.
    ///   - newViewport: Elements from the new viewport (viewport-relative Y).
    ///   - cumulativeOffset: Total scroll offset accumulated so far.
    ///   - viewportOffset: Scroll offset for this specific viewport transition.
    ///   - windowHeight: Height of the target window.
    ///   - strategy: Deduplication strategy for text matching.
    /// - Returns: Merged element list with page-absolute Y coordinates.
    static func merge(
        accumulated: [TapPoint], newViewport: [TapPoint],
        cumulativeOffset: Double, viewportOffset: Double,
        windowHeight: Double, strategy: ScrollDedupStrategy
    ) -> [TapPoint] {
        guard !newViewport.isEmpty else { return accumulated }
        guard !accumulated.isEmpty else {
            // First viewport: project to absolute Y (offset is 0)
            return newViewport.map { toAbsolute($0, offset: cumulativeOffset) }
        }

        let existingTexts = Set(accumulated.map(\.text))
        var result = accumulated

        // Compute the overlap zone in page-absolute coordinates.
        // Elements with viewport-relative Y in [0, windowHeight - viewportOffset]
        // potentially overlap with previously seen content.
        let overlapThreshold = windowHeight - abs(viewportOffset)

        for el in newViewport {
            // Skip elements we've already seen (text-based dedup)
            if existingTexts.contains(el.text) {
                continue
            }

            // Check if element might be in the overlap zone using fuzzy text matching
            let absoluteY = toAbsoluteY(el.tapY, cumulativeOffset: cumulativeOffset)
            let isDuplicate: Bool
            switch strategy {
            case .exact:
                isDuplicate = false
            case .levenshtein:
                isDuplicate = accumulated.contains { existing in
                    abs(existing.tapY - absoluteY) < overlapYTolerance
                    && levenshteinDistance(existing.text, el.text) <= 3
                }
            case .proximity:
                isDuplicate = accumulated.contains { existing in
                    abs(existing.tapY - absoluteY) < overlapYTolerance
                    && abs(existing.tapX - el.tapX) < overlapYTolerance
                }
            }

            if isDuplicate { continue }

            // Element is in the non-overlapping portion — project to absolute Y
            if el.tapY >= overlapThreshold || !existingTexts.contains(el.text) {
                result.append(toAbsolute(el, offset: cumulativeOffset))
            }
        }

        return result.sorted { $0.tapY < $1.tapY }
    }

    /// Convert a viewport-relative Y coordinate to page-absolute Y.
    static func toAbsoluteY(_ viewportY: Double, cumulativeOffset: Double) -> Double {
        viewportY + cumulativeOffset
    }

    // MARK: - Private

    private static func toAbsolute(_ el: TapPoint, offset: Double) -> TapPoint {
        TapPoint(
            text: el.text,
            tapX: el.tapX,
            tapY: toAbsoluteY(el.tapY, cumulativeOffset: offset),
            confidence: el.confidence
        )
    }

    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count
        guard m > 0 else { return n }
        guard n > 0 else { return m }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[n]
    }
}
