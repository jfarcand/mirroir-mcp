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

    /// The whole label of the button an App Store result shows for an app that
    /// is not installed ("Obtenir"). Pattern data: `## Spotlight Store Button`
    /// in `system-phrases.md`.
    static var storeButtonLabels: [String] { SystemPhrases.live.phrases(.spotlightStoreButton) }

    /// Widest vertical gap, in points, between a store result's name and its
    /// button (20pt measured on an XR).
    static let storeButtonReach = 40.0

    /// Whether Return would open an app, not a web suggestion, an App Store page
    /// or a message: the search field says it opens the result, or Spotlight has
    /// a top result and it is a tile. The field is enough on its own: Spotlight
    /// can show an app's top hit without a heading above it (iOS 27,
    /// 2026-11-16: "Horloge — Ouvrir" over the Horloge tile row, no heading).
    /// Neither counts when the first result named `name` is an App Store card:
    /// the field says it opens that card too. Looks at the screen before Return
    /// because nothing afterwards names the app in front.
    ///
    /// A field that says it opens a result must hold `name` itself: Spotlight
    /// says "Open" over a web suggestion too, and a held query the typing was
    /// added to reads as another query (XR, iOS 18, carnet#99: "settingsgoogle
    /// classroomgoogle… — Open" opened a Brave search and launch_app reported
    /// Settings launched). The tile under the heading counts only while no such
    /// field is read: its label can be the app's name in the iPhone's language.
    static func returnOpensApp(elements: [TapPoint], name: String) -> Bool {
        if firstResultIsStoreCard(elements: elements, name: name) { return false }
        let openQueries = elements.compactMap(openFieldQuery)
        if !openQueries.isEmpty { return openQueries.contains(normalize(name)) }
        return holdsQuery(elements: elements) && SpotlightAppTile.topHit(in: elements) != nil
    }

    /// Whether the highest result whose text is `name` has a store button on its
    /// row: the App Store's card for an app that is not installed. The field's
    /// own text ("OpenTable — Ouvrir") never reads as `name` alone.
    static func firstResultIsStoreCard(elements: [TapPoint], name: String) -> Bool {
        let target = normalize(name)
        guard !target.isEmpty,
              let result = elements.filter({ normalize($0.text) == target }).min(by: { $0.tapY < $1.tapY })
        else { return false }
        return elements.contains { element in
            storeButtonLabels.contains(SystemPhrases.fold(element.text.trimmingCharacters(in: .whitespaces)))
                && abs(element.tapY - result.tapY) <= storeButtonReach
        }
    }

    /// The query of the field's completion, normalized: `element` reads as the
    /// query, a dash, then the word for open ("Q Horloge - Ouvrir" holds
    /// "horloge"). Nil for any other text.
    private static func openFieldQuery(_ element: TapPoint) -> String? {
        let parts = element.text.split(whereSeparator: { "-–—".contains($0) })
        guard parts.count >= 2, let last = parts.last,
              openWords.contains(SystemPhrases.fold(last.trimmingCharacters(in: .whitespaces)))
        else { return nil }
        let query = parts.dropLast().joined(separator: "-")
        return normalize(searchFieldText(query) ?? query)
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

    /// The fractions of the window height where Spotlight's search field can sit.
    /// iOS 26 docks it at the bottom (an XR, 430x942: y 872 of 942, and an
    /// iOS 27 phone on 2026-11-04: y 829 of 898); iOS 27 was also seen with it
    /// at the top (2026-11-12, 410x898). The field is taken in either band, so
    /// the layout on screen decides, not the iOS version.
    static let searchFieldBands: [ClosedRange<Double>] = [0.0 ... 0.2, 0.8 ... 1.0]

    /// Fraction of the window height below which the Home Screen's search pill
    /// sits. Only the bottom: an app opening on a search field at its top
    /// ("Q Rechercher" in Settings) must not read as the Home Screen.
    static let homeSearchPillBandStart = 0.8

    /// Fraction of the window height above which the Home Screen's search
    /// pill sits: the Dock is below it (iPhone 16 at 736 of 898, XR at 783 of
    /// 942, 82-83%). Settings' own search field on iOS 26 and 27 ("Q
    /// Rechercher" at 838 of 898) and Spotlight's idle field (872 of 942) sit
    /// at the bottom edge, 93%, and are not the Home Screen.
    static let homeSearchPillBandEnd = 0.88

    /// Whether `y` lies in one of Spotlight's search-field bands of a window
    /// `windowHeight` points tall.
    static func isInSearchFieldBand(_ y: Double, windowHeight: Double) -> Bool {
        searchFieldBands.contains { band in
            (band.lowerBound * windowHeight ... band.upperBound * windowHeight).contains(y)
        }
    }

    /// The text Spotlight's search field shows after its magnifier glyph, or
    /// nil when no element in a search-field band reads as the field.
    static func searchFieldQuery(elements: [TapPoint], windowHeight: Double) -> String? {
        elements.lazy
            .filter { isInSearchFieldBand($0.tapY, windowHeight: windowHeight) }
            .compactMap { searchFieldText($0.text) }
            .first
    }

    /// Shortest normalized text treated as an echo of the query, so single
    /// OCR glyphs never count.
    static let minEchoLength = 3

    /// Check whether Spotlight's search field still echoes `query`.
    ///
    /// When Spotlight finds nothing, it shows no "Top Hit" label — only a blurred
    /// background and the search field, which OCR reads with the magnifier glyph
    /// first ("Q Maps"), at the bottom or the top of the screen (`searchFieldBands`).
    /// The glyph is required: an app's own bottom text (a "Horloges" tab after
    /// launching Horloge) must not count. OCR may truncate
    /// the text, so the field's text and the query only need to be prefixes of
    /// one another once normalized.
    static func isQueryEchoedInSearchField(
        elements: [TapPoint], query: String, windowHeight: Double
    ) -> Bool {
        let target = normalize(query)
        guard target.count >= minEchoLength else { return false }
        return elements.contains { el in
            guard isInSearchFieldBand(el.tapY, windowHeight: windowHeight),
                  let field = searchFieldText(el.text) else { return false }
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
        homeSearchPill(in: elements, windowHeight: windowHeight) != nil
    }

    /// The Home Screen's search pill, the last row above the Dock, or nil.
    static func homeSearchPill(in elements: [TapPoint], windowHeight: Double) -> TapPoint? {
        let band = windowHeight * homeSearchPillBandStart ... windowHeight * homeSearchPillBandEnd
        return elements.first { el in
            guard band.contains(el.tapY), let field = searchFieldText(el.text) else { return false }
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
    static func searchFieldText(_ text: String) -> String? {
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
