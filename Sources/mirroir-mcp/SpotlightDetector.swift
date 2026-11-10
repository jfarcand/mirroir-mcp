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

    /// The heading above Spotlight's top result. A query with no installed app,
    /// file or message behind it has none (measured on an XR, iOS 26: "Keynote",
    /// not installed, lists a web suggestion and an App Store row under
    /// "Suggestions"). Pattern data: `## Spotlight Top Hit` in `system-phrases.md`.
    static var topHitHeadings: [String] { SystemPhrases.live.phrases(.spotlightTopHit) }

    /// What the search field adds after the query when Return opens an app
    /// ("Notes — Ouvrir"); on any other top result it adds that result's title.
    /// Pattern data: `## Spotlight Open` in `system-phrases.md`.
    static var openWords: [String] { SystemPhrases.live.phrases(.spotlightOpen) }

    /// Whether Spotlight holds a query: its top-hit heading shows. The idle page
    /// (Siri suggestions) holds none, and typing reaches it.
    static func holdsQuery(elements: [TapPoint]) -> Bool {
        elements.contains { el in
            topHitHeadings.contains { SystemPhrases.fold(el.text).contains($0) }
        }
    }

    /// Whether Return would open an app, not a web suggestion, an App Store page
    /// or a message: Spotlight has a top result, and either the search field says
    /// it opens it, or the result is a tile. Looks at the screen before Return
    /// because nothing afterwards names the app in front.
    static func returnOpensApp(elements: [TapPoint]) -> Bool {
        guard holdsQuery(elements: elements) else { return false }
        return elements.contains(where: fieldSaysOpen)
            || SpotlightAppTile.topHit(in: elements) != nil
    }

    /// Whether `element` reads as the field's completion: the query, a dash, then
    /// the word for open ("Q Horloge - Ouvrir").
    private static func fieldSaysOpen(_ element: TapPoint) -> Bool {
        let parts = element.text.split(whereSeparator: { "-–—".contains($0) })
        guard parts.count >= 2, let last = parts.last else { return false }
        let word = SystemPhrases.fold(last.trimmingCharacters(in: .whitespaces))
        return openWords.contains(word)
    }

    /// Text that indicates Spotlight search overlay is still visible: the
    /// top-hit headings and `## Spotlight Overlay` in `system-phrases.md`.
    static var indicators: [String] {
        topHitHeadings + SystemPhrases.live.phrases(.spotlightOverlay)
    }

    /// Check if the current screen shows Spotlight search overlay.
    static func isSpotlightVisible(elements: [TapPoint]) -> Bool {
        elements.contains { el in
            let lower = SystemPhrases.fold(el.text)
            return indicators.contains { lower.contains($0) }
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
    /// Pattern data: `## Home Search Pill` in `system-phrases.md`.
    static var homeSearchPillLabels: [String] { SystemPhrases.live.phrases(.homeSearchPill) }

    /// Whether the home screen's search pill is showing, i.e. no app is in front.
    static func isHomeScreenVisible(elements: [TapPoint], windowHeight: Double) -> Bool {
        let bandTop = windowHeight * searchFieldBandStart
        return elements.contains { el in
            guard el.tapY >= bandTop, let field = searchFieldText(el.text) else { return false }
            return homeSearchPillLabels.contains(SystemPhrases.fold(field))
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
