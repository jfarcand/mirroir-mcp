// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Computes structural fingerprints from OCR elements for screen identity in the navigation graph.
// ABOUTME: Filters dynamic content (timestamps, counters) and uses SHA256 for stable comparison.

import CryptoKit
import Foundation
import HelperLib

/// Computes structural fingerprints from OCR elements for screen identity.
/// Filters dynamic content (timestamps, counters, badges) to produce stable
/// fingerprints that survive minor OCR variations between captures of the same screen.
enum StructuralFingerprint {

    /// Similarity threshold above which two fingerprint element sets are considered the same screen.
    /// At 0.8, scrolled list views (60-80% element retention) are detected as same screen.
    static let similarityThreshold: Double = 0.8

    /// Maximum text length for an element to be considered structural.
    /// Long strings are likely dynamic content (paragraphs, descriptions).
    static let maxStructuralLength = 50

    /// Y range for the header zone (title bar area). Elements here are strongly structural.
    static let headerZoneRange: ClosedRange<Double> = 100...250

    /// Bottom percentage of screen considered tab bar zone. Elements here are structural.
    static let tabBarFraction: Double = 0.15

    // MARK: - Screen Fingerprint

    /// Build a `ScreenFingerprint` from OCR elements and detected icons.
    /// Used at compile time to capture the app's visual state for content drift detection.
    static func buildScreenFingerprint(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon]
    ) -> ScreenFingerprint {
        let structural = extractStructural(from: elements)
        let sorted = structural.sorted()
        let hash = compute(elements: elements, icons: icons)
        return ScreenFingerprint(
            hash: hash,
            structuralTexts: sorted,
            iconCount: icons.count
        )
    }

    /// Compute Jaccard similarity between two `ScreenFingerprint` values.
    /// Fast-path: if hashes match, returns 1.0 without set comparison.
    static func screenFingerprintSimilarity(
        _ lhs: ScreenFingerprint, _ rhs: ScreenFingerprint
    ) -> Double {
        if lhs.hash == rhs.hash { return 1.0 }
        let lhsSet = Set(lhs.structuralTexts)
        let rhsSet = Set(rhs.structuralTexts)
        return similarity(lhsSet, rhsSet)
    }

    // MARK: - Entry Point

    /// Compute a SHA256-based fingerprint string from screen elements and icons.
    /// The fingerprint is stable across captures of the same screen despite OCR noise.
    static func compute(elements: [TapPoint], icons: [IconDetector.DetectedIcon]) -> String {
        let structural = extractStructural(from: elements)
        let sorted = structural.sorted()

        // Include icon count as a coarse structural signal.
        // Icon positions vary slightly between captures, but count is stable.
        let iconSignal = "icons:\(icons.count)"
        let payload = (sorted + [iconSignal]).joined(separator: "|")

        let hash = SHA256.hash(data: Data(payload.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Extract the set of structural text elements, filtering out dynamic content.
    /// Structural elements are stable across captures: headers, labels, menu items.
    /// Dynamic elements change between captures: timestamps, counters, badges.
    static func extractStructural(from elements: [TapPoint]) -> Set<String> {
        var result = Set<String>()
        for el in elements {
            guard passesStructuralFilter(el) else { continue }
            result.insert(el.text)
        }
        return result
    }

    /// Compute Jaccard similarity between two sets of structural elements (0.0-1.0).
    static func similarity(
        _ lhs: Set<String>, _ rhs: Set<String>
    ) -> Double {
        let union = lhs.union(rhs)
        guard !union.isEmpty else { return 1.0 }
        return Double(lhs.intersection(rhs).count) / Double(union.count)
    }

    /// Check if two element arrays represent the same screen using structural similarity.
    static func areEquivalent(_ lhs: [TapPoint], _ rhs: [TapPoint]) -> Bool {
        let leftSet = extractStructural(from: lhs)
        let rightSet = extractStructural(from: rhs)
        return similarity(leftSet, rightSet) >= similarityThreshold
    }

    // MARK: - Title-Aware Similarity

    /// Extract the probable nav bar title from OCR elements.
    /// Picks the longest text in the header zone (100–250pt Y), excluding time patterns,
    /// bare numbers, dates, and text shorter than 3 characters.
    static func extractNavBarTitle(from elements: [TapPoint]) -> String? {
        var candidate: String?
        var candidateLength = 0
        for el in elements {
            guard headerZoneRange.contains(el.tapY) else { continue }
            guard el.text.count >= 3 else { continue }
            guard !LandmarkPicker.isTimePattern(el.text) else { continue }
            guard !LandmarkPicker.isBareNumber(el.text) else { continue }
            guard !isDatePattern(el.text) else { continue }
            if el.text.count > candidateLength {
                candidate = el.text
                candidateLength = el.text.count
            }
        }
        return candidate
    }

    /// Compute similarity with a nav bar title short-circuit.
    /// If both element sets have extractable titles that differ, returns 0.0 immediately.
    /// Otherwise falls through to standard Jaccard similarity.
    static func titleAwareSimilarity(_ lhs: [TapPoint], _ rhs: [TapPoint]) -> Double {
        let leftTitle = extractNavBarTitle(from: lhs)
        let rightTitle = extractNavBarTitle(from: rhs)
        // Short-circuit: both have titles and they differ → definitely different screens.
        if let lt = leftTitle, let rt = rightTitle, lt != rt {
            return 0.0
        }
        let leftSet = extractStructural(from: lhs)
        let rightSet = extractStructural(from: rhs)
        return similarity(leftSet, rightSet)
    }

    /// Check if two element arrays represent the same screen, using title-aware comparison.
    /// If both screens have distinct nav bar titles, they are never considered equivalent.
    static func areEquivalentTitleAware(_ lhs: [TapPoint], _ rhs: [TapPoint]) -> Bool {
        titleAwareSimilarity(lhs, rhs) >= similarityThreshold
    }

    // MARK: - Viewport Containment

    /// Check if a viewport's elements are mostly contained within a larger calibrated
    /// element set. Standard Jaccard fails when comparing a single viewport (~40 elements)
    /// against a full-page calibrated set (~90 elements) because the viewport is a subset,
    /// not a match. Containment measures what fraction of the viewport's structural elements
    /// appear in the reference set.
    static func viewportContainedIn(
        viewport: [TapPoint], reference: [TapPoint], threshold: Double = 0.6
    ) -> Bool {
        let viewportSet = extractStructural(from: viewport)
        guard !viewportSet.isEmpty else { return false }
        let referenceSet = extractStructural(from: reference)
        let contained = viewportSet.intersection(referenceSet).count
        return Double(contained) / Double(viewportSet.count) >= threshold
    }

    // MARK: - Filtering

    /// Determine if an element is structural (stable across captures).
    static func passesStructuralFilter(_ el: TapPoint) -> Bool {
        // Exclude status bar elements
        guard el.tapY >= LandmarkPicker.statusBarMaxY else { return false }

        // Exclude time patterns (clock in status bar that leaked past Y filter)
        guard !LandmarkPicker.isTimePattern(el.text) else { return false }

        // Exclude bare numbers (battery %, signal, counters, badges)
        guard !LandmarkPicker.isBareNumber(el.text) else { return false }

        // Exclude very long text (likely dynamic paragraph content)
        guard el.text.count <= maxStructuralLength else { return false }

        // Exclude date-like patterns (e.g. "Feb 23", "2/23/26", "Monday")
        guard !isDatePattern(el.text) else { return false }

        return true
    }

    /// Check if text matches common date/day patterns that change over time.
    static func isDatePattern(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let dayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let shortDays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        let months = [
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december",
        ]
        let shortMonths = [
            "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
        ]

        // Full or abbreviated day/month names as standalone text
        if dayNames.contains(lowered) || shortDays.contains(lowered) { return true }
        if months.contains(lowered) || shortMonths.contains(lowered) { return true }

        // Patterns like "Feb 23" or "Mar 5"
        let parts = lowered.split(separator: " ")
        if parts.count == 2,
           (shortMonths.contains(String(parts[0])) || months.contains(String(parts[0]))),
           parts[1].allSatisfy(\.isNumber) {
            return true
        }

        return false
    }
}
