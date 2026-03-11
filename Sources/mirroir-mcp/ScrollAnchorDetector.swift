// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Detects fixed UI anchors (tab bar, nav bar) across scroll viewports to compute scroll offset.
// ABOUTME: Compares element positions between consecutive viewports to determine overlap zones.

import Foundation
import HelperLib

/// Detects fixed UI anchors across scroll viewports and computes the scroll offset.
/// Fixed elements (tab bars, nav bars) maintain their Y position across scrolls.
/// By finding matching text in anchor zones and measuring position delta, we can
/// compute the exact overlap between consecutive viewports.
enum ScrollAnchorDetector {

    /// A matched anchor element found in both previous and current viewports.
    struct AnchorMatch: Sendable {
        /// The text of the matched element.
        let text: String
        /// Y position in the previous viewport.
        let previousY: Double
        /// Y position in the current viewport.
        let currentY: Double
        /// Computed scroll offset (previousY - currentY) for this anchor.
        var scrollOffset: Double { previousY - currentY }
    }

    /// Result of computing scroll offset from anchors.
    struct OffsetResult: Sendable {
        /// Median scroll offset computed from matching anchors.
        let scrollOffset: Double
        /// Number of anchor matches used to compute the offset.
        let anchorCount: Int
    }

    /// Fraction of window height defining the top anchor zone (nav bar area).
    static let topAnchorFraction: Double = 0.18

    /// Fraction of window height defining the bottom anchor zone (tab bar area).
    static let bottomAnchorFraction: Double = 0.85

    /// Compute the scroll offset between two consecutive viewports using fixed anchors.
    ///
    /// Anchors are elements that appear at the same Y position in both viewports
    /// (tab bar items, nav bar titles). By matching text in anchor zones, we determine
    /// how much the content scrolled between captures.
    ///
    /// - Parameters:
    ///   - previous: Elements from the previous viewport.
    ///   - current: Elements from the current viewport.
    ///   - windowHeight: Height of the target window.
    ///   - minAnchors: Minimum anchor matches required for a valid result.
    /// - Returns: The offset result, or nil if fewer than `minAnchors` match.
    static func computeOffset(
        previous: [TapPoint], current: [TapPoint],
        windowHeight: Double, minAnchors: Int
    ) -> OffsetResult? {
        let matches = findAnchors(
            previous: previous, current: current, windowHeight: windowHeight
        )
        guard matches.count >= minAnchors else { return nil }
        let offset = medianOffset(from: matches)
        return OffsetResult(scrollOffset: offset, anchorCount: matches.count)
    }

    /// Find matching anchor elements between two viewports.
    /// Only considers elements in the top and bottom anchor zones, and matches
    /// elements within the SAME zone to avoid cross-zone false matches
    /// (e.g. "Résumé" page title in top zone matching "Résumé" tab bar in bottom zone).
    static func findAnchors(
        previous: [TapPoint], current: [TapPoint], windowHeight: Double
    ) -> [AnchorMatch] {
        let topZone = windowHeight * topAnchorFraction
        let bottomZone = windowHeight * bottomAnchorFraction

        // Build per-zone lookups for current viewport anchors
        var currentTop: [String: TapPoint] = [:]
        var currentBottom: [String: TapPoint] = [:]
        for el in current {
            if el.tapY <= topZone {
                currentTop[el.text] = el
            } else if el.tapY >= bottomZone {
                currentBottom[el.text] = el
            }
        }

        var matches: [AnchorMatch] = []
        for el in previous {
            // Match within the same zone only
            let lookup: [String: TapPoint]?
            if el.tapY <= topZone {
                lookup = currentTop
            } else if el.tapY >= bottomZone {
                lookup = currentBottom
            } else {
                lookup = nil
            }
            if let currentEl = lookup?[el.text] {
                matches.append(AnchorMatch(
                    text: el.text,
                    previousY: el.tapY,
                    currentY: currentEl.tapY
                ))
            }
        }
        return matches
    }

    /// Compute the median scroll offset from a list of anchor matches.
    static func medianOffset(from matches: [AnchorMatch]) -> Double {
        guard !matches.isEmpty else { return 0.0 }
        let offsets = matches.map(\.scrollOffset).sorted()
        let mid = offsets.count / 2
        if offsets.count.isMultiple(of: 2) {
            return (offsets[mid - 1] + offsets[mid]) / 2.0
        }
        return offsets[mid]
    }

    // MARK: - Content-Based Offset Detection

    /// Compute scroll offset using content elements visible in both viewports.
    ///
    /// Unlike `computeOffset()` which uses fixed anchors (tab/nav bar),
    /// this matches mid-screen content elements by (text, nearX). Elements
    /// in anchor zones (top/bottom of viewport) are excluded because stationary
    /// elements (tab bar, nav bar) produce zero-delta matches that dominate the
    /// median and mask the actual content scroll distance.
    ///
    /// - Parameters:
    ///   - previous: Elements from the previous viewport.
    ///   - current: Elements from the current viewport.
    ///   - windowHeight: Height of the target window for zone filtering.
    ///   - xTolerance: Maximum X distance for a match.
    ///   - outlierThreshold: Maximum deviation from median to keep a delta.
    ///   - minMatches: Minimum matches required for a valid result.
    /// - Returns: The offset result, or nil if too few matches.
    static func computeContentOffset(
        previous: [TapPoint], current: [TapPoint],
        windowHeight: Double = 0,
        xTolerance: Double = EnvConfig.scrollContentMatchXTolerance,
        outlierThreshold: Double = EnvConfig.scrollContentMatchOutlierThreshold,
        minMatches: Int = EnvConfig.scrollContentMatchMinCount
    ) -> OffsetResult? {
        // Exclude anchor zones (nav bar top, tab bar bottom) to avoid stationary
        // elements producing zero-delta matches that overwhelm the median.
        let topZone = windowHeight > 0 ? windowHeight * topAnchorFraction : 0
        let bottomZone = windowHeight > 0 ? windowHeight * bottomAnchorFraction : Double.infinity

        // Build a spatial index: text → [(x, y)] for previous content elements
        var prevIndex: [String: [(x: Double, y: Double)]] = [:]
        for el in previous where el.tapY > topZone && el.tapY < bottomZone {
            prevIndex[el.text, default: []].append((x: el.tapX, y: el.tapY))
        }

        // Find matching content elements across viewports
        var deltas: [Double] = []
        var currentContentCount = 0
        for el in current where el.tapY > topZone && el.tapY < bottomZone {
            currentContentCount += 1
            guard let candidates = prevIndex[el.text] else { continue }
            // Find the closest X match
            if let best = candidates.min(by: { abs($0.x - el.tapX) < abs($1.x - el.tapX) }),
               abs(best.x - el.tapX) < xTolerance {
                deltas.append(best.y - el.tapY)
            }
        }

        DebugLog.persist("ContentMatch", "prev=\(prevIndex.count) curr=\(currentContentCount) deltas=\(deltas.count) values=\(deltas.map { Int($0) })")

        guard deltas.count >= minMatches else { return nil }

        // Robust offset: compute median, filter outliers, recompute median
        let rawMedian = medianValue(deltas)
        let filtered = deltas.filter { abs($0 - rawMedian) <= outlierThreshold }
        guard filtered.count >= minMatches else { return nil }

        let offset = medianValue(filtered)
        return OffsetResult(scrollOffset: offset, anchorCount: filtered.count)
    }

    // MARK: - Private

    /// Compute the median of a non-empty Double array.
    private static func medianValue(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }

    private static func isInAnchorZone(
        y: Double, topZone: Double, bottomZone: Double
    ) -> Bool {
        y <= topZone || y >= bottomZone
    }
}
