// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Detects iOS system alerts (permission prompts, rating dialogs, tracking consent) from OCR elements.
// ABOUTME: Returns the most conservative dismiss target to safely close unexpected dialogs.

import Foundation
import HelperLib

/// A detected iOS system alert with a recommended dismiss target.
struct DetectedAlert: Sendable {
    /// The OCR element to tap to dismiss the alert.
    let dismissTarget: TapPoint
    /// A human-readable description of the detected alert type.
    let alertType: String
}

/// Detects iOS system alerts from OCR elements and recommends safe dismiss targets.
/// Recognizes permission prompts, rating dialogs, tracking consent, and similar modal dialogs.
enum AlertDetector {

    /// Button texts that indicate an alert dialog, in dismiss priority order
    /// (most conservative first): `## Alert Dismiss` in `system-phrases.md`,
    /// whose file order is the priority.
    static var dismissPriority: [(text: String, priority: Int)] {
        SystemPhrases.live.phrases(.alertDismiss).enumerated().map { ($0.element, $0.offset) }
    }

    /// Title patterns that strongly indicate an alert dialog: `## Alert Title`
    /// in `system-phrases.md`, `.*` standing for any text.
    static var titlePatterns: [String] { SystemPhrases.live.phrases(.alertTitle) }

    /// Maximum element count for a screen to be considered an alert.
    /// Real alerts are small overlays with few elements; normal screens have many more.
    static let maxAlertElementCount = 10

    /// Minimum number of indicator matches to confirm an alert.
    static let minIndicatorMatches = 2

    /// Maximum dismiss attempts before giving up.
    static let maxDismissAttempts = 3

    /// Detect whether the current screen elements represent an iOS system alert.
    ///
    /// Detection criteria:
    /// 1. Total element count must be small (< maxAlertElementCount)
    /// 2. At least minIndicatorMatches button indicators found, OR a title pattern matches
    /// 3. Returns the best dismiss target by conservative priority
    ///
    /// - Parameter elements: OCR elements from the current screen.
    /// - Returns: A `DetectedAlert` if the screen looks like a system dialog, nil otherwise.
    static func detectAlert(elements: [TapPoint]) -> DetectedAlert? {
        guard elements.count < maxAlertElementCount else { return nil }
        guard elements.count >= 2 else { return nil }

        // Find matching dismiss buttons with their priorities
        var matches: [(element: TapPoint, priority: Int)] = []
        let buttons = dismissPriority
        for element in elements {
            let lowered = SystemPhrases.fold(element.text)
            for (buttonText, priority) in buttons {
                if lowered == buttonText {
                    matches.append((element: element, priority: priority))
                    break
                }
            }
        }

        // Check title patterns
        let titles = titlePatterns
        let hasTitlePattern = elements.contains { element in
            let lowered = SystemPhrases.fold(element.text)
            return titles.contains { pattern in
                lowered.contains(pattern) || matchesRegexLike(text: lowered, pattern: pattern)
            }
        }

        // Need at least 2 button indicators OR 1 button + title pattern match
        let hasEnoughIndicators = matches.count >= minIndicatorMatches
        let hasTitleAndButton = hasTitlePattern && !matches.isEmpty
        guard hasEnoughIndicators || hasTitleAndButton else { return nil }

        // Pick the most conservative dismiss target (lowest priority number)
        guard let best = matches.min(by: { $0.priority < $1.priority }) else { return nil }

        let alertType = hasTitlePattern ? "permission/tracking dialog" : "system alert"
        return DetectedAlert(dismissTarget: best.element, alertType: alertType)
    }

    /// Simple pattern matching that handles ".*" wildcard in patterns.
    private static func matchesRegexLike(text: String, pattern: String) -> Bool {
        guard pattern.contains(".*") else { return text.contains(pattern) }
        let parts = pattern.components(separatedBy: ".*")
        guard parts.count == 2 else { return text.contains(pattern) }
        guard let firstRange = text.range(of: parts[0]) else { return false }
        let remaining = text[firstRange.upperBound...]
        return remaining.contains(parts[1])
    }
}
