/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Filters OCR elements to select the best landmark for wait_for steps.
// ABOUTME: Removes status bar noise, time patterns, and bare numbers before picking.

import Foundation
import HelperLib

/// Picks the most distinctive OCR element as a landmark from a list of tap points.
/// Filters out status bar noise, time patterns, bare numbers, and short/long text.
enum LandmarkPicker {

    /// Minimum character length for a landmark candidate.
    static let landmarkMinLength = 3
    /// Maximum character length for a landmark candidate.
    static let landmarkMaxLength = 40
    /// Minimum OCR confidence for a landmark candidate.
    static let landmarkMinConfidence: Float = 0.5
    /// Elements with tapY below this threshold are considered status bar and skipped.
    static let statusBarMaxY: Double = 80
    /// Preferred Y range for title/header zone landmarks.
    static let headerZoneRange: ClosedRange<Double> = 100...250
    /// Regex matching status bar time patterns like "12:25", "9:41", "12:251".
    static let timePattern = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2,3}$"#)
    /// Regex matching bare short numbers (battery %, signal strength).
    static let bareNumberPattern = try! NSRegularExpression(pattern: #"^\d{1,3}$"#)

    /// Pick the most distinctive OCR element as a landmark, filtering out status bar noise.
    /// Skips elements in the status bar zone (tapY < 80), time patterns, and bare numbers.
    /// Candidates whose text contains an `excludedPatterns` entry (case-insensitive)
    /// are removed before any tier runs.
    ///
    /// Tier ladder, checked in order:
    /// - Tier 0: first candidate whose whole text equals a `stableAnchors` entry
    ///   (case-insensitive, whitespace-trimmed) — returns the anchor's declared
    ///   text. Whole-text matching keeps feed content that merely contains an
    ///   anchor substring ("Home" inside "Homemade granola bars") from posing
    ///   as the anchor's own label.
    /// - Tier 0.5: the nav bar title from `StructuralFingerprint.extractNavBarTitle`,
    ///   when that title also passes the candidate filter.
    /// - Tier 1: structural candidates in header zone (100-250pt Y) — most stable.
    /// - Tier 2: any structural candidate (topmost).
    /// - Tier 3: topmost qualifying element (original behavior).
    ///
    /// Tiers 0/0.5 run only when the caller opted into stable-anchor selection
    /// (non-empty `stableAnchors` or `requireStable`); calls with all-default
    /// arguments keep the original Tier 1-3 ladder byte-for-byte.
    ///
    /// When `requireStable` is true and Tiers 0/0.5 find nothing, returns nil —
    /// an omitted wait step beats an ephemeral one on infinite-scroll screens.
    static func pickLandmark(
        from elements: [TapPoint],
        stableAnchors: [String] = [],
        excludedPatterns: [String] = [],
        requireStable: Bool = false
    ) -> String? {
        let exclusions = excludedPatterns.map { $0.lowercased() }
        let candidates = elements.filter { el in
            el.text.count >= landmarkMinLength &&
            el.text.count <= landmarkMaxLength &&
            el.confidence >= landmarkMinConfidence &&
            el.tapY >= statusBarMaxY &&
            !isTimePattern(el.text) &&
            !isBareNumber(el.text) &&
            // Back-navigation chrome ("<", "< Back") renders on every detail
            // screen — it can never identify the destination screen.
            !NavigationHintDetector.isBackNavigationText(el.text) &&
            !ActionStepFormatter.isExcludedLabel(el.text) &&
            !exclusions.contains { el.text.lowercased().contains($0) }
        }

        // The stable tiers (0 and 0.5) run only when the caller supplied
        // stable-anchor context: all-default calls keep the original ladder so
        // labeled-app landmark picks are unchanged.
        if !stableAnchors.isEmpty || requireStable {
            // Tier 0: declared stable anchor visible on screen (e.g. APP.md tab
            // name). Whole-text match — an anchor embedded inside longer text is
            // feed content, not the anchor's own label.
            for candidate in candidates {
                let lowerText = candidate.text
                    .trimmingCharacters(in: .whitespaces).lowercased()
                if let anchor = stableAnchors.first(where: { $0.lowercased() == lowerText }) {
                    return anchor
                }
            }

            // Tier 0.5: nav bar title, when it also survives the candidate filter.
            // Back-navigation chrome is dropped before extraction so a "< Back"
            // button cannot shadow the actual title beside it.
            let titleSource = elements.filter {
                !NavigationHintDetector.isBackNavigationText($0.text)
            }
            if let title = StructuralFingerprint.extractNavBarTitle(from: titleSource),
               candidates.contains(where: { $0.text == title }) {
                return title
            }

            // No stable tier matched — omitting the wait step beats an ephemeral anchor
            if requireStable { return nil }
        }

        // Tier 1: Structural candidates in header zone (100-250pt Y) — most stable
        let structuralHeader = candidates.filter {
            headerZoneRange.contains($0.tapY) && StructuralFingerprint.passesStructuralFilter($0)
        }
        if let best = structuralHeader.sorted(by: { $0.tapY < $1.tapY }).first {
            return best.text
        }

        // Tier 2: Any structural candidate (topmost)
        let structural = candidates.filter { StructuralFingerprint.passesStructuralFilter($0) }
        if let best = structural.sorted(by: { $0.tapY < $1.tapY }).first {
            return best.text
        }

        // Tier 3: Fallback to topmost qualifying element (original behavior)
        let headerCandidates = candidates.filter { headerZoneRange.contains($0.tapY) }
        if let best = headerCandidates.sorted(by: { $0.tapY < $1.tapY }).first {
            return best.text
        }
        return candidates.sorted(by: { $0.tapY < $1.tapY }).first?.text
    }

    /// Check if a string matches a status bar time pattern like "12:25" or "9:41".
    static func isTimePattern(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return timePattern.firstMatch(in: text, range: range) != nil
    }

    /// Check if a string is a bare short number (1-3 digits, e.g. battery/signal).
    static func isBareNumber(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return bareNumberPattern.firstMatch(in: text, range: range) != nil
    }

    /// Check if a string contains no alphanumeric characters (e.g. "...", "•••", "→", "+++").
    /// These are typically UI indicators or action icons, not useful navigation targets.
    static func isPunctuationOnly(_ text: String) -> Bool {
        !text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
