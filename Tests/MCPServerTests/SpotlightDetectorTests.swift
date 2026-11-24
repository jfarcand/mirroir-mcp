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
// ABOUTME: Tests for SpotlightDetector: verifying Spotlight overlay detection from OCR elements.
// ABOUTME: Covers English, French indicators and false-positive rejection for normal app screens.

import XCTest
@testable import mirroir_mcp
@testable import HelperLib

final class SpotlightDetectorTests: XCTestCase {

    // MARK: - Spotlight Detection

    func testDetectsEnglishSpotlight() {
        let elements = [
            TapPoint(text: "Settings", tapX: 200, tapY: 100, confidence: 0.9),
            TapPoint(text: "Top Hit", tapX: 200, tapY: 200, confidence: 0.9),
            TapPoint(text: "Search in App", tapX: 200, tapY: 300, confidence: 0.9),
        ]

        XCTAssertTrue(SpotlightDetector.isSpotlightVisible(elements: elements))
    }

    func testDetectsFrenchSpotlight() {
        let elements = [
            TapPoint(text: "Réglages", tapX: 200, tapY: 100, confidence: 0.9),
            TapPoint(text: "Meilleur résultat", tapX: 200, tapY: 200, confidence: 0.9),
            TapPoint(text: "Rechercher dans l'app", tapX: 200, tapY: 300, confidence: 0.9),
        ]

        XCTAssertTrue(SpotlightDetector.isSpotlightVisible(elements: elements))
    }

    func testDetectsSpanishSpotlight() {
        let elements = [
            TapPoint(text: "Ajustes", tapX: 200, tapY: 100, confidence: 0.9),
            TapPoint(text: "Sugerencias de Siri", tapX: 200, tapY: 200, confidence: 0.9),
        ]

        XCTAssertTrue(SpotlightDetector.isSpotlightVisible(elements: elements))
    }

    func testDetectsGermanSpotlight() {
        let elements = [
            TapPoint(text: "Einstellungen", tapX: 200, tapY: 100, confidence: 0.9),
            TapPoint(text: "Siri-Vorschläge", tapX: 200, tapY: 200, confidence: 0.9),
        ]

        XCTAssertTrue(SpotlightDetector.isSpotlightVisible(elements: elements))
    }

    func testIsCaseInsensitive() {
        let elements = [
            TapPoint(text: "top hit", tapX: 200, tapY: 200, confidence: 0.9),
        ]

        XCTAssertTrue(SpotlightDetector.isSpotlightVisible(elements: elements))
    }

    // MARK: - Normal App Screens (False Positive Rejection)

    func testSettingsRootNotDetectedAsSpotlight() {
        let elements = [
            TapPoint(text: "Réglages", tapX: 100, tapY: 179, confidence: 0.9),
            TapPoint(text: "Jeanfrancois Arcand", tapX: 207, tapY: 240, confidence: 0.9),
            TapPoint(text: "Wi-Fi", tapX: 104, tapY: 556, confidence: 0.9),
            TapPoint(text: "Bluetooth", tapX: 120, tapY: 609, confidence: 0.9),
            TapPoint(text: "Batterie", tapX: 110, tapY: 767, confidence: 0.9),
        ]

        XCTAssertFalse(SpotlightDetector.isSpotlightVisible(elements: elements))
    }

    func testSlackHomeNotDetectedAsSpotlight() {
        let elements = [
            TapPoint(text: "Home", tapX: 115, tapY: 727, confidence: 0.9),
            TapPoint(text: "DMs", tapX: 162, tapY: 728, confidence: 0.9),
            TapPoint(text: "Activity", tapX: 208, tapY: 728, confidence: 0.9),
            TapPoint(text: "More", tapX: 255, tapY: 728, confidence: 0.9),
        ]

        XCTAssertFalse(SpotlightDetector.isSpotlightVisible(elements: elements))
    }

    func testEmptyElementsNotDetectedAsSpotlight() {
        XCTAssertFalse(SpotlightDetector.isSpotlightVisible(elements: []))
    }

    // MARK: - Partial Indicator Match

    func testDetectsPartialIndicatorInText() {
        // "Siri Suggestions" contained within a longer element text
        let elements = [
            TapPoint(text: "Show Siri Suggestions on Lock Screen", tapX: 200, tapY: 300, confidence: 0.9),
        ]

        XCTAssertTrue(SpotlightDetector.isSpotlightVisible(elements: elements))
    }

    // MARK: - What Return opens

    private func point(_ text: String, _ x: Double, _ y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.9)
    }

    private var icon: String { CoreMLElementDetector.iconLabel }

    func testAFieldSayingOpenMeansReturnOpensAnApp() {
        let screen = [point("Meilleur résultat", 86, 107), point("Q Horloge - Ouvrir", 133, 874)]
        XCTAssertTrue(SpotlightDetector.returnOpensApp(elements: screen, name: "Horloge"))
        let english = [point("Top Hit", 86, 107), point("Clock — Open", 133, 874)]
        XCTAssertTrue(SpotlightDetector.returnOpensApp(elements: english, name: "Clock"))
    }

    /// iOS 27, 2026-11-16 (carnet#76): the top hit showed with no heading
    /// above it; only the field said Return opens it.
    func testAFieldSayingOpenNeedsNoHeading() {
        let screen = [
            point("Horloge — Ouvrir", 137, 101), point(icon, 168, 166), point("Horloge", 79, 266),
            point("Régler le", 163, 265), point("Réglages", 76, 319),
            point("Rechercher dans l'app Q", 287, 320),
        ]
        XCTAssertFalse(SpotlightDetector.holdsQuery(elements: screen))
        XCTAssertTrue(SpotlightDetector.returnOpensApp(elements: screen, name: "Horloge"))
    }

    /// XR, iOS 18, 2026-11-24 (carnet#99): "google classroom" in Spotlight. The
    /// field says "Open" over an App Store card and a Brave web suggestion.
    private var googleClassroomScreen: [TapPoint] {
        [
            point("Top Hit", 45, 96), point("Google Classroom", 161, 132), point("Get", 285, 148),
            point("Education", 130, 149), point(icon, 187, 151), point("Suggestions", 61, 216),
            point("google classroom", 115, 253), point("Siri Knowledge", 68, 298),
            point("Search in Apps", 68, 661), point("• google classroom - Open", 144, 731),
        ]
    }

    func testAFieldOpeningAnotherQueryIsNotTheNamedApp() {
        XCTAssertFalse(SpotlightDetector.returnOpensApp(elements: googleClassroomScreen, name: "Settings"))
        let prefixed = googleClassroomScreen.map {
            $0.text.hasSuffix("- Open") ? point("Q settingsgoogle classroomgoogl - Open", 144, 731) : $0
        }
        XCTAssertFalse(SpotlightDetector.returnOpensApp(elements: prefixed, name: "Settings"),
                       "typing added to a held query names another search")
    }

    func testAFieldOpeningAnAppStoreCardIsNoApp() {
        XCTAssertFalse(SpotlightDetector.returnOpensApp(elements: googleClassroomScreen, name: "Google Classroom"))
    }

    func testAFieldNamingAnotherResultWithoutAHeadingIsNoApp() {
        let screen = [point("M/t/o - Clinique dentaire St-Sauve", 189, 101), point(icon, 168, 166),
                      point("Horloge", 79, 266)]
        XCTAssertFalse(SpotlightDetector.returnOpensApp(elements: screen, name: "M/t/o"))
    }

    func testATileUnderTheHeadingCountsWhenTheFieldIsUnread() {
        let screen = [point("Meilleur résultat", 86, 107), point(icon, 81, 188), point("Météo", 79, 219)]
        XCTAssertTrue(SpotlightDetector.returnOpensApp(elements: screen, name: "Weather"),
                      "an English name on a French iPhone still has an app as its top hit")
    }

    /// iOS 27 phone, 2026-11-04: "M/t/o" typed, and the top result was a Mail message.
    func testAMessageAsTopResultIsNotAnApp() {
        let screen = [
            point("Meilleur résultat", 82, 118), point("Clinique dentair...", 195, 172),
            point("Clinique dentaire St-Sauveur", 220, 193), point("CS", 77, 202), point(icon, 203, 206),
            point("Bonjour M. Jean Francois Arcand,", 238, 213),
            point("Nous désirons vous rappeler votr...", 241, 232),
            point("Q M/t/o - Clinique dentaire St-Sauve", 189, 829),
        ]
        XCTAssertFalse(SpotlightDetector.returnOpensApp(elements: screen, name: "M/t/o"))
    }

    /// XR, iOS 26, 2026-11-15 (carnet#74): OpenTable not installed. The top hit
    /// was its App Store card, and the field still said Return opens it.
    private var storeCardScreen: [TapPoint] {
        [
            point("Meilleur résultat", 86, 107), point("OpenTable", 165, 151), point("Obtenir", 342, 171),
            point("Food & Drink", 167, 172), point(icon, 202, 174), point("Suggestions", 72, 253),
            point("OpenTable", 111, 298), point(icon, 42, 299), point("OpenTable - Ouvrir", 158, 874),
        ]
    }

    func testAnAppStoreCardAsTopHitIsNoApp() {
        XCTAssertTrue(SpotlightDetector.firstResultIsStoreCard(elements: storeCardScreen, name: "OpenTable"))
        XCTAssertFalse(SpotlightDetector.returnOpensApp(elements: storeCardScreen, name: "OpenTable"))
    }

    func testAnAppStoreCardWithoutAHeadingIsNoApp() {
        let screen = storeCardScreen.filter { $0.text != "Meilleur résultat" }
        XCTAssertFalse(SpotlightDetector.returnOpensApp(elements: screen, name: "OpenTable"))
    }

    func testAStoreButtonFarBelowAnInstalledAppDoesNotCount() {
        let screen = [
            point("Horloge — Ouvrir", 137, 101), point(icon, 168, 166), point("Horloge", 79, 266),
            point("Horloge Mondiale", 165, 420), point("Obtenir", 342, 430),
        ]
        XCTAssertFalse(SpotlightDetector.firstResultIsStoreCard(elements: screen, name: "Horloge"))
        XCTAssertTrue(SpotlightDetector.returnOpensApp(elements: screen, name: "Horloge"))
    }

    func testNoTopHitMeansNoApp() {
        let screen = [point("Suggestions", 72, 108), point(icon, 42, 153), point("Keynote", 101, 154),
                      point("Keynote", 107, 872)]
        XCTAssertFalse(SpotlightDetector.returnOpensApp(elements: screen, name: "Keynote"))
        XCTAssertFalse(SpotlightDetector.holdsQuery(elements: screen))
    }

    /// iOS 27, 2026-11-16 (carnet#76): Spotlight opened as a bare field
    /// over the Home Screen, with no suggestions; only its placeholder shows it.
    func testABareSearchFieldIsSpotlight() {
        let screen = [point("Rechercher ou demander", 172, 98), point("Horloge", 159, 159),
                      point("Q Rechercher", 205, 736)]
        XCTAssertTrue(SpotlightDetector.isSpotlightVisible(elements: screen))
        XCTAssertFalse(SpotlightDetector.isSpotlightVisible(elements: [point("Q Rechercher", 205, 736)]),
                       "the Home Screen's search pill is not Spotlight")
    }

    /// iPhone 16, iOS 27, 2026-11-18: Settings ends on its own "Q Rechercher"
    /// field at the bottom edge. Read as the Home Screen, a tap on "Réseau
    /// cellulaire" was lifted to the icon above the label and opened Bluetooth.
    func testSettingsBottomSearchFieldIsNotTheHomeScreen() {
        let settings = [point("Mode Avion", 129, 511), point("Wi-Fi", 106, 561), point("Bluetooth", 121, 614),
                        point("Réseau cellulaire", 148, 667), point("Q Rechercher", 109, 838)]
        XCTAssertFalse(SpotlightDetector.isHomeScreenVisible(elements: settings, windowHeight: 898))
        XCTAssertTrue(SpotlightDetector.isHomeScreenVisible(
            elements: [point("Horloge", 159, 159), point("Q Rechercher", 205, 736)], windowHeight: 898),
                      "the Home Screen's pill sits above the Dock")
    }

    func testTheIdlePageHoldsNoQuery() {
        let screen = [point("Suggestions de Siri", 97, 109), point(icon, 171, 189), point("Notes", 170, 218)]
        XCTAssertFalse(SpotlightDetector.holdsQuery(elements: screen))
        XCTAssertTrue(SpotlightDetector.isSpotlightVisible(elements: screen))
    }
}
