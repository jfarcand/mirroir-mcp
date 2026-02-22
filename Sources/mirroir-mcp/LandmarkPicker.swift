// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
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
    /// Prefers elements in the header zone (100-250pt Y range) over others.
    static func pickLandmark(from elements: [TapPoint]) -> String? {
        let candidates = elements.filter { el in
            el.text.count >= landmarkMinLength &&
            el.text.count <= landmarkMaxLength &&
            el.confidence >= landmarkMinConfidence &&
            el.tapY >= statusBarMaxY &&
            !isTimePattern(el.text) &&
            !isBareNumber(el.text)
        }

        // Prefer elements in the header zone (100-250pt Y range)
        let headerCandidates = candidates.filter { headerZoneRange.contains($0.tapY) }

        if let best = headerCandidates.sorted(by: { $0.tapY < $1.tapY }).first {
            return best.text
        }

        // Fall back to topmost qualifying element outside status bar
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
}
