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
    /// Only considers elements in the top and bottom anchor zones.
    static func findAnchors(
        previous: [TapPoint], current: [TapPoint], windowHeight: Double
    ) -> [AnchorMatch] {
        let topZone = windowHeight * topAnchorFraction
        let bottomZone = windowHeight * bottomAnchorFraction

        // Build a lookup for current viewport anchors by text
        var currentByText: [String: TapPoint] = [:]
        for el in current {
            guard isInAnchorZone(y: el.tapY, topZone: topZone, bottomZone: bottomZone) else {
                continue
            }
            currentByText[el.text] = el
        }

        var matches: [AnchorMatch] = []
        for el in previous {
            guard isInAnchorZone(y: el.tapY, topZone: topZone, bottomZone: bottomZone) else {
                continue
            }
            if let currentEl = currentByText[el.text] {
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

    // MARK: - Private

    private static func isInAnchorZone(
        y: Double, topZone: Double, bottomZone: Double
    ) -> Bool {
        y <= topZone || y >= bottomZone
    }
}
