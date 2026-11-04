// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
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
        XCTAssertTrue(SpotlightDetector.returnOpensApp(elements: screen))
        let english = [point("Top Hit", 86, 107), point("Clock — Open", 133, 874)]
        XCTAssertTrue(SpotlightDetector.returnOpensApp(elements: english))
    }

    func testATileUnderTheHeadingCountsWhenTheFieldIsUnread() {
        let screen = [point("Meilleur résultat", 86, 107), point(icon, 81, 188), point("Météo", 79, 219)]
        XCTAssertTrue(SpotlightDetector.returnOpensApp(elements: screen),
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
        XCTAssertFalse(SpotlightDetector.returnOpensApp(elements: screen))
    }

    func testNoTopHitMeansNoApp() {
        let screen = [point("Suggestions", 72, 108), point(icon, 42, 153), point("Keynote", 101, 154),
                      point("Keynote", 107, 872)]
        XCTAssertFalse(SpotlightDetector.returnOpensApp(elements: screen))
        XCTAssertFalse(SpotlightDetector.holdsQuery(elements: screen))
    }

    func testTheIdlePageHoldsNoQuery() {
        let screen = [point("Suggestions de Siri", 97, 109), point(icon, 171, 189), point("Notes", 170, 218)]
        XCTAssertFalse(SpotlightDetector.holdsQuery(elements: screen))
        XCTAssertTrue(SpotlightDetector.isSpotlightVisible(elements: screen))
    }
}
