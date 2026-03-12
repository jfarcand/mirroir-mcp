// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Resolves stale calibration coordinates to fresh viewport coordinates by displayLabel matching.
// ABOUTME: Returns scroll instruction when a plan item is not visible in the current viewport.

import Foundation
import HelperLib

/// Resolves plan items (built from calibrated full-page data) against current viewport OCR
/// to produce fresh tap coordinates. Plan items carry `displayLabel` for identity; this
/// resolver finds the matching element in the live viewport by text.
/// Pure transformation: all static methods, no stored state.
enum PlanCoordinateResolver {

    /// Result of resolving a single plan item against viewport elements.
    enum Resolution {
        /// Element found in current viewport with fresh coordinates.
        case found(freshPoint: TapPoint)
        /// Element not visible in current viewport — need to scroll to find it.
        case needsScroll
    }

    /// Match a plan item's displayLabel against current viewport OCR elements.
    ///
    /// Matching strategy (in priority order):
    /// 1. Exact text match on `displayLabel`
    /// 2. Case-insensitive match
    /// 3. Containment match (viewport element contains displayLabel or vice versa)
    ///
    /// - Parameters:
    ///   - planItem: The ranked element from the calibrated plan.
    ///   - viewportElements: Current viewport OCR elements with fresh coordinates.
    /// - Returns: `.found` with fresh coordinates or `.needsScroll`.
    static func resolve(
        planItem: RankedElement,
        viewportElements: [TapPoint]
    ) -> Resolution {
        let label = planItem.displayLabel

        // 1. Exact match
        if let match = viewportElements.first(where: { $0.text == label }) {
            return .found(freshPoint: match)
        }

        // 2. Case-insensitive match
        let lowerLabel = label.lowercased()
        if let match = viewportElements.first(where: { $0.text.lowercased() == lowerLabel }) {
            return .found(freshPoint: match)
        }

        // 3. Containment match (handles OCR truncation or extra whitespace).
        // Both sides must be at least 5 characters to prevent short strings like
        // battery "68" from matching plan labels containing that substring
        // (e.g. "568 calories par jour au cours des" contains "68").
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let minContainmentLength = 5
        if trimmedLabel.count >= minContainmentLength {
            if let match = viewportElements.first(where: {
                let trimmed = $0.text.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= minContainmentLength else { return false }
                return trimmed.contains(trimmedLabel) || trimmedLabel.contains(trimmed)
            }) {
                return .found(freshPoint: match)
            }
        }

        return .needsScroll
    }

    /// Resolve a plan item with fresh coordinates, preserving the plan's score and metadata.
    ///
    /// - Parameters:
    ///   - planItem: Original plan item with stale coordinates.
    ///   - freshPoint: Fresh TapPoint from the current viewport.
    /// - Returns: A new RankedElement with fresh coordinates and original scoring.
    static func withFreshCoordinates(
        planItem: RankedElement,
        freshPoint: TapPoint
    ) -> RankedElement {
        RankedElement(
            point: freshPoint,
            score: planItem.score,
            reason: planItem.reason,
            displayLabel: planItem.displayLabel,
            isBreadthNavigation: planItem.isBreadthNavigation
        )
    }
}
