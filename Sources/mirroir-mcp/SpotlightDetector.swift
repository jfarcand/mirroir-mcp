// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Detects Spotlight search overlay on the iPhone screen via OCR element analysis.
// ABOUTME: Used after app launch (explorer and launch_app) to verify the app opened instead of Spotlight lingering.

import Foundation
import HelperLib

/// Detects whether iOS Spotlight search overlay is currently visible on screen.
/// Used to verify app readiness after launch — Spotlight may linger if the app
/// takes time to open or if the Return key didn't register.
enum SpotlightDetector {

    /// Maximum poll attempts before giving up on Spotlight dismissal.
    static let maxRetries = 5

    /// Delay between poll attempts in milliseconds.
    static let retryDelayMs: UInt32 = 500

    /// Text patterns that indicate Spotlight search overlay is still visible.
    /// Covers English, French, Spanish, and German locales.
    static let indicators: [String] = [
        "Top Hit", "Meilleur résultat",
        "Search in App", "Rechercher dans l'app",
        "Siri Suggestions", "Suggestions de Siri",
        "Siri-Vorschläge", "Sugerencias de Siri",
    ]

    /// Check if the current screen shows Spotlight search overlay.
    static func isSpotlightVisible(elements: [TapPoint]) -> Bool {
        elements.contains { el in
            let lower = el.text.lowercased()
            return indicators.contains { lower.contains($0.lowercased()) }
        }
    }

    /// Fraction of the window height below which Spotlight's search field sits.
    /// iOS keeps the field docked at the bottom in both orientations.
    static let searchFieldBandStart = 0.8

    /// Shortest normalized text treated as an echo of the query, so single
    /// OCR glyphs never count.
    static let minEchoLength = 3

    /// Check whether Spotlight's search field still echoes `query`.
    ///
    /// When Spotlight finds nothing, it shows no "Top Hit" label — only a blurred
    /// background and the search field, which OCR reads with the magnifier glyph
    /// first ("Q Maps"). The glyph is required: an app's own bottom text (a
    /// "Horloges" tab after launching Horloge) must not count. OCR may truncate
    /// the text, so the field's text and the query only need to be prefixes of
    /// one another once normalized.
    static func isQueryEchoedInSearchField(
        elements: [TapPoint], query: String, windowHeight: Double
    ) -> Bool {
        let target = normalize(query)
        guard target.count >= minEchoLength else { return false }
        let bandTop = windowHeight * searchFieldBandStart
        return elements.contains { el in
            guard el.tapY >= bandTop, let field = searchFieldText(el.text) else { return false }
            let text = normalize(field)
            guard text.count >= minEchoLength else { return false }
            return target.hasPrefix(text) || text.hasPrefix(target)
        }
    }

    /// Labels of the home screen's search pill, which OCR reads as "Q Rechercher".
    /// Seeing it after a launch means the home screen is still showing.
    static let homeSearchPillLabels: [String] = ["search", "rechercher", "buscar", "suchen"]

    /// Whether the home screen's search pill is showing, i.e. no app is in front.
    static func isHomeScreenVisible(elements: [TapPoint], windowHeight: Double) -> Bool {
        let bandTop = windowHeight * searchFieldBandStart
        return elements.contains { el in
            guard el.tapY >= bandTop, let field = searchFieldText(el.text) else { return false }
            return homeSearchPillLabels.contains(field.lowercased())
        }
    }

    /// Whether Spotlight is still showing after a launch attempt for `query`:
    /// either its result labels or its search field echoing the query.
    static func isSpotlightVisible(
        elements: [TapPoint], query: String, windowHeight: Double
    ) -> Bool {
        isSpotlightVisible(elements: elements)
            || isQueryEchoedInSearchField(elements: elements, query: query, windowHeight: windowHeight)
    }

    /// Outcome of confirming that a Spotlight launch opened the app.
    enum LaunchVerification: Equatable {
        /// Spotlight is gone from the screen.
        case launched
        /// Spotlight is still on screen after every poll.
        case spotlightStillVisible
        /// The home screen is still showing: Spotlight never opened or closed
        /// without launching anything.
        case stillOnHomeScreen
        /// The screen could not be read, so the launch is unconfirmed.
        case unreadable
    }

    /// Poll the screen until Spotlight is gone after launching `query`.
    static func verifyLaunch(
        describer: ScreenDescribing, query: String, windowHeight: Double,
        retryDelayUs: UInt32 = retryDelayMs * 1000
    ) -> LaunchVerification {
        var last: LaunchVerification = .unreadable
        for attempt in 0..<maxRetries {
            if attempt > 0 { usleep(retryDelayUs) }
            guard let result = describer.describe() else { continue }
            if isSpotlightVisible(elements: result.elements, query: query, windowHeight: windowHeight) {
                last = .spotlightStillVisible
            } else if isHomeScreenVisible(elements: result.elements, windowHeight: windowHeight) {
                last = .stillOnHomeScreen
            } else {
                return .launched
            }
        }
        return last
    }

    /// Prefixes OCR produces for the magnifier glyph in iOS search fields.
    static let searchGlyphPrefixes: [String] = ["Q ", "🔍"]

    /// The text after the magnifier glyph, or nil when `text` does not start with it.
    private static func searchFieldText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for glyph in searchGlyphPrefixes where trimmed.hasPrefix(glyph) {
            return String(trimmed.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Poll until Spotlight is dismissed, returning the first clean screen result.
    /// Returns nil if Spotlight persists after all retries.
    static func waitForDismissal(
        describer: ScreenDescribing
    ) -> ScreenDescriber.DescribeResult? {
        for _ in 0..<maxRetries {
            usleep(retryDelayMs * 1000)
            guard let result = describer.describe() else { continue }
            if !isSpotlightVisible(elements: result.elements) {
                return result
            }
        }
        return nil
    }
}
