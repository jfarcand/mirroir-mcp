// ABOUTME: Detects when the explorer has left the target app (home screen, lock screen, system dialogs).
// ABOUTME: Returns a diagnosis used by ExplorerUtilities.verifyAppContext to trigger recovery or graceful stop.

import Foundation
import HelperLib

/// Diagnosis of whether the explorer is still inside the target app.
enum AppContextDiagnosis: Sendable, Equatable {
    /// The screen appears to be inside an app (back chevron, few short labels, etc.).
    case inApp
    /// The screen looks like the iOS home screen (grid of short app-icon labels).
    case homeScreen
    /// The screen matches a known system/lock screen pattern.
    case lockOrSystemScreen(description: String)
}

/// Detects when the DFS/BFS explorer has escaped the target app.
/// Recognizes home screen grids and system/lock screen patterns from OCR elements.
/// Used by ExplorerUtilities.verifyAppContext for app context safety guardrails.
enum AppContextDetector {

    /// Minimum number of short-label candidates to trigger home screen detection.
    static let minHomeScreenCandidates = 8

    /// Minimum number of distinct Y-bands to confirm a home screen grid layout.
    static let minYBands = 3

    /// Minimum average candidates per Y-band to confirm grid layout.
    /// Home screen rows have 3-4 icons each. App list screens have ~1 per row.
    static let minCandidatesPerBand: Double = 2.0

    /// Maximum character count for a candidate home screen icon label.
    static let maxLabelLength = 14

    /// Minimum character count for a candidate home screen icon label.
    static let minLabelLength = 2

    /// Tolerance in points for grouping elements into the same coordinate band.
    static let bandTolerance: Double = 30.0

    /// Known system/lock screen text patterns (lowercased for case-insensitive matching).
    static let systemScreenPatterns: [String] = [
        "iphone in use",
        "lock your iphone",
        "slide to unlock",
        "enter passcode",
        "face id",
        "swipe up to open",
        "press home to open",
        "emergency",
    ]

    /// Diagnose whether OCR elements indicate the explorer is still inside an app,
    /// or has escaped to the home screen or a system screen.
    ///
    /// - Parameters:
    ///   - elements: OCR elements from the current screen.
    ///   - screenHeight: Height of the mirroring window in points.
    /// - Returns: A diagnosis of the current screen context.
    static func diagnose(elements: [TapPoint], screenHeight: Double) -> AppContextDiagnosis {
        // Check system/lock screen first (quick string match)
        if let systemMatch = detectSystemScreen(elements: elements) {
            return .lockOrSystemScreen(description: systemMatch)
        }

        // Check home screen grid pattern
        if detectHomeScreen(elements: elements, screenHeight: screenHeight) {
            return .homeScreen
        }

        return .inApp
    }

    // MARK: - Home Screen Detection

    /// Maximum X coordinate for the back button position on iOS nav bars.
    static let backButtonMaxX: Double = 80.0

    /// Detect the iOS home screen: many short labels arranged in a grid pattern,
    /// with no back chevron (which would indicate being inside an app).
    static func detectHomeScreen(elements: [TapPoint], screenHeight: Double) -> Bool {
        let topZone = screenHeight * NavigationHintDetector.topZoneFraction

        // If there's a back chevron in the top zone, we're inside an app
        let hasBackChevron = elements.contains { el in
            let trimmed = el.text.trimmingCharacters(in: .whitespaces)
            return NavigationHintDetector.backChevronPatterns.contains(trimmed)
                && el.tapY <= topZone
        }
        if hasBackChevron { return false }

        // OCR sometimes detects the "<" back chevron as "icon" via YOLO.
        // A lone icon in the top-left corner (back button position) indicates
        // an app nav bar, not a home screen. Home screens don't have a single
        // icon at this position — their icon grid starts much further down.
        let hasBackButtonIcon = elements.contains { el in
            el.text.lowercased() == "icon"
                && el.tapX <= backButtonMaxX
                && el.tapY <= topZone
                && el.tapY > screenHeight * 0.05
        }
        if hasBackButtonIcon { return false }

        // Filter candidates: below status bar, short text, not time/number patterns,
        // not YOLO detection labels ("icon" is a generic YOLO class, not a readable label).
        let statusBarCutoff = screenHeight * 0.10
        let candidates = elements.filter { el in
            el.tapY > statusBarCutoff
                && el.text.count >= minLabelLength
                && el.text.count <= maxLabelLength
                && !isTimeOrNumberPattern(el.text)
                && el.text.lowercased() != "icon"
        }

        guard candidates.count >= minHomeScreenCandidates else { return false }

        // Verify grid layout: many rows AND multiple elements per row.
        // Home screen rows have 3-4 icon labels each. App list screens have ~1 per row.
        let yBands = countDistinctBands(candidates.map(\.tapY))
        guard yBands >= minYBands else { return false }
        let avgPerBand = Double(candidates.count) / Double(yBands)
        return avgPerBand >= minCandidatesPerBand
    }

    /// Count distinct coordinate bands by grouping values within tolerance.
    /// Used for both Y-bands (rows) and X-bands (columns) in grid detection.
    static func countDistinctBands(_ values: [Double]) -> Int {
        let sorted = values.sorted()
        guard let first = sorted.first else { return 0 }

        var bands = 1
        var currentBand = first
        for v in sorted.dropFirst() {
            if v - currentBand > bandTolerance {
                bands += 1
                currentBand = v
            }
        }
        return bands
    }

    /// Filter out status bar noise: time strings (e.g. "9:41", "12:00") and bare numbers.
    static func isTimeOrNumberPattern(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Bare number (e.g. battery percentage)
        if Double(trimmed) != nil { return true }
        // Time pattern: digits:digits (e.g. "9:41", "12:00")
        let parts = trimmed.split(separator: ":")
        if parts.count == 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return true
        }
        // Percentage (e.g. "85%")
        if trimmed.hasSuffix("%"),
           Double(trimmed.dropLast()) != nil {
            return true
        }
        return false
    }

    // MARK: - System/Lock Screen Detection

    /// Check if any element text matches a known system/lock screen pattern.
    /// Returns the matched pattern description, or nil if no match.
    static func detectSystemScreen(elements: [TapPoint]) -> String? {
        for element in elements {
            let lowered = element.text.lowercased()
            for pattern in systemScreenPatterns {
                if lowered.contains(pattern) {
                    return pattern
                }
            }
        }
        return nil
    }
}
