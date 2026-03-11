// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Merges new viewport elements into an accumulated page using scroll offset deduplication.
// ABOUTME: Uses composite key (text + quantized X) and page-absolute Y for robust overlap detection.

import Foundation
import HelperLib

/// Merges OCR elements from scrolled viewports into an accumulated list
/// with page-absolute coordinates. Uses composite keys (text + X bucket)
/// and page-absolute Y for accurate overlap detection.
enum OverlapDeduplicator {

    /// Build a composite dedup key from text and quantized X position.
    /// Elements with the same text at similar X positions are considered the same element,
    /// while elements with the same text at different X positions are kept separate
    /// (e.g., "icon" at x=50 and x=350 are distinct elements).
    static func compositeKey(
        _ el: TapPoint,
        bucketSize: Double = EnvConfig.scrollDedupXBucketSize
    ) -> String {
        let xBucket = Int(el.tapX / bucketSize) * Int(bucketSize)
        return "\(el.text)@\(xBucket)"
    }

    /// Merge new viewport elements into the accumulated element list.
    ///
    /// Uses composite key (text + quantized X) for primary dedup, then checks
    /// page-absolute Y proximity for overlap detection. Elements carry both
    /// viewport-relative `tapY` and page-absolute `pageY`.
    ///
    /// - Parameters:
    ///   - accumulated: Previously collected elements with page-absolute pageY.
    ///   - newViewport: Elements from the new viewport (viewport-relative coordinates).
    ///   - cumulativeOffset: Total scroll offset accumulated so far.
    ///   - viewportOffset: Scroll offset for this specific viewport transition.
    ///   - windowHeight: Height of the target window.
    ///   - strategy: Deduplication strategy for fuzzy matching.
    /// - Returns: Merged element list sorted by page-absolute Y.
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

        let pageYTolerance = EnvConfig.scrollDedupPageYTolerance

        // Build composite key index with page-absolute Y for existing elements
        var existingByKey: [String: [Double]] = [:]
        for el in accumulated {
            let key = compositeKey(el)
            existingByKey[key, default: []].append(el.pageY)
        }

        var result = accumulated

        for el in newViewport {
            let absoluteY = el.tapY + cumulativeOffset
            let key = compositeKey(el)

            // Check composite key + pageY proximity for duplicates
            var isDuplicate = false
            if let existingYs = existingByKey[key] {
                isDuplicate = existingYs.contains { abs($0 - absoluteY) < pageYTolerance }
            }

            // Additional fuzzy checks for non-exact strategies
            if !isDuplicate {
                switch strategy {
                case .exact:
                    break
                case .levenshtein:
                    isDuplicate = accumulated.contains { existing in
                        abs(existing.pageY - absoluteY) < pageYTolerance
                        && abs(existing.tapX - el.tapX) < EnvConfig.scrollContentMatchXTolerance
                        && levenshteinDistance(existing.text, el.text) <= EnvConfig.scrollDedupLevenshteinMax
                    }
                case .proximity:
                    isDuplicate = accumulated.contains { existing in
                        abs(existing.pageY - absoluteY) < pageYTolerance
                        && abs(existing.tapX - el.tapX) < EnvConfig.scrollContentMatchXTolerance
                    }
                }
            }

            if !isDuplicate {
                let projected = toAbsolute(el, offset: cumulativeOffset)
                result.append(projected)
                existingByKey[key, default: []].append(absoluteY)
            }
        }

        return result.sorted { $0.pageY < $1.pageY }
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
            tapY: el.tapY,
            confidence: el.confidence,
            pageY: el.tapY + offset
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
