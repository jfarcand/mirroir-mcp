// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for AppSwitcherCardLocator: matches foreground app OCR text against App Switcher OCR to find the app's card position.
// ABOUTME: Covers single-card layout, multi-card carousel, the no-match path, and label-first locating of clipped cards.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class AppSwitcherCardLocatorTests: XCTestCase {

    private func tap(_ text: String, x: Double, y: Double = 200) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    // MARK: - Single-card layout

    func testReturnsCenterXWhenOnlyTargetCardVisible() {
        // Foreground Santé app with distinctive text.
        let app: [TapPoint] = [
            tap("Résumé", x: 92), tap("Épinglés", x: 88),
            tap("Activité", x: 82), tap("Bouger", x: 67),
            tap("Entraînements", x: 107), tap("Distance", x: 155),
        ]
        // App Switcher with only Santé (centered, smaller font).
        let switcher: [TapPoint] = [
            tap("Résumé", x: 200), tap("Épinglés", x: 198),
            tap("Activité", x: 195), tap("Bouger", x: 200),
        ]
        let result = AppSwitcherCardLocator.locateCardX(
            appElements: app, switcherElements: switcher, windowWidth: 410
        )
        XCTAssertNotNil(result)
        if let r = result {
            XCTAssert(r >= 195 && r <= 200, "Should center on the only card; got \(r)")
        }
    }

    // MARK: - Multi-card layout

    func testFindsRightmostCardInThreeCardCarousel() {
        // Foreground Santé.
        let app: [TapPoint] = [
            tap("Résumé", x: 92), tap("Épinglés", x: 88),
            tap("Activité", x: 82), tap("Bouger", x: 67),
            tap("680 cal", x: 80), tap("Entraînements", x: 107),
        ]
        // App Switcher: Messages on left, Tapo center, Santé right.
        let switcher: [TapPoint] = [
            // Messages card content (left, x ~50-70)
            tap("Vous", x: 60),
            tap("Sans toi...pi", x: 71),
            tap("Ah oui? Pd", x: 70),
            tap("Pis? Comn", x: 70),
            // Tapo card content (center, x ~150-200)
            tap("Tapo", x: 176),
            tap("01/36", x: 114),
            // Santé card content (right, x ~340-370) — these are the matches
            tap("Résumé", x: 359),
            tap("Épinglés", x: 357),
            tap("Activité", x: 358),
            tap("Bouger", x: 343),
            tap("680 cal", x: 350),
            tap("Entraînemen", x: 363),  // truncated in App Switcher OCR
        ]
        let result = AppSwitcherCardLocator.locateCardX(
            appElements: app, switcherElements: switcher, windowWidth: 410
        )
        XCTAssertNotNil(result)
        if let r = result {
            XCTAssert(r >= 340 && r <= 370,
                "Should locate Santé card at right (x ~340-370); got \(r)")
        }
    }

    // MARK: - No match fallback

    func testReturnsNilWhenNoTextOverlap() {
        let app: [TapPoint] = [
            tap("Réglages", x: 50), tap("Wi-Fi", x: 50), tap("Bluetooth", x: 50),
        ]
        // App Switcher shows completely different apps.
        let switcher: [TapPoint] = [
            tap("Tapo", x: 176),
            tap("Vous", x: 60),
            tap("Sans toi", x: 70),
        ]
        XCTAssertNil(AppSwitcherCardLocator.locateCardX(
            appElements: app, switcherElements: switcher, windowWidth: 410
        ))
    }

    func testReturnsNilWhenAppOcrEmpty() {
        let switcher: [TapPoint] = [tap("Résumé", x: 200)]
        XCTAssertNil(AppSwitcherCardLocator.locateCardX(
            appElements: [], switcherElements: switcher, windowWidth: 410
        ))
    }

    func testReturnsNilWhenSwitcherOcrEmpty() {
        let app: [TapPoint] = [tap("Résumé", x: 92)]
        XCTAssertNil(AppSwitcherCardLocator.locateCardX(
            appElements: app, switcherElements: [], windowWidth: 410
        ))
    }

    func testIgnoresShortNoiseFragments() {
        // Single-character OCR noise should not anchor matching.
        let app: [TapPoint] = [
            tap("X", x: 50), tap(".", x: 60), tap("longerword", x: 70),
        ]
        // Switcher with the noise but at a different cluster than the real word.
        let switcher: [TapPoint] = [
            tap("X", x: 380), tap(".", x: 380),
            tap("longerword", x: 100),
        ]
        let result = AppSwitcherCardLocator.locateCardX(
            appElements: app, switcherElements: switcher, windowWidth: 410
        )
        // Only "longerword" should match (X and . are too short).
        XCTAssertEqual(result ?? -1, 100, accuracy: 1)
    }

    func testCaseInsensitiveMatching() {
        let app: [TapPoint] = [tap("RÉSUMÉ", x: 92), tap("ÉPINGLÉS", x: 88)]
        let switcher: [TapPoint] = [
            tap("résumé", x: 359), tap("épinglés", x: 360),
        ]
        let result = AppSwitcherCardLocator.locateCardX(
            appElements: app, switcherElements: switcher, windowWidth: 410
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result ?? -1, 359.5, accuracy: 1)
    }

    // MARK: - Regressions: wrong-app force-quit

    /// The bug that quit the wrong app: on a French multi-app switcher the
    /// just-launched app's card was center, but a clipped far-left card whose
    /// OCR caught common tab labels ("Accueil"/"Recherche") out-voted it and got
    /// dragged. The locator must reject the left sliver and pick the center card.
    func testRejectsClippedLeftEdgeCardWithCommonWords() {
        let app: [TapPoint] = [
            tap("@johndoe", x: 60), tap("Belle journée à la plage", x: 100),
            tap("@janesmithphoto", x: 60),
            tap("Accueil", x: 30), tap("Recherche", x: 90), tap("Reels", x: 160),
        ]
        // Clipped left-edge card (x<82) OCRs only the common tab words;
        // Instagram's real card is centered with the distinctive content.
        let switcher: [TapPoint] = [
            tap("Accueil", x: 40), tap("Recherche", x: 55), tap("Reels", x: 47),
            tap("@johndoe", x: 200), tap("Belle journée à la plage", x: 205),
            tap("@janesmithphoto", x: 198),
        ]
        let result = AppSwitcherCardLocator.locateCardX(
            appElements: app, switcherElements: switcher, windowWidth: 410
        )
        XCTAssertNotNil(result)
        if let r = result {
            XCTAssert(r >= 190 && r <= 230,
                "Must pick the center card, not the clipped left-edge card; got \(r)")
        }
    }

    func testSingleShortTokenDoesNotLocate() {
        // One stray common word shared with a neighboring card must not count
        // as finding the app's card — this exact ghost match made the
        // post-dismiss verification report an already-dismissed card as still
        // present (the dismissed app's rich fingerprint intersected the
        // remaining cards on a single short token).
        let app: [TapPoint] = [
            tap("Votre story", x: 60), tap("dans", x: 200),
            tap("un long caption de publication instagram", x: 210),
        ]
        let switcher: [TapPoint] = [tap("dans", x: 206)]
        XCTAssertNil(
            AppSwitcherCardLocator.locateCardX(
                appElements: app, switcherElements: switcher, windowWidth: 410
            ),
            "A single short-token intersection is not evidence of the card")
    }

    func testRichOverlapStillLocatesAboveMinScore() {
        // A genuine card preview shares several full lines — comfortably above
        // the minimum-evidence floor.
        let app: [TapPoint] = [
            tap("Votre story", x: 60), tap("festival_de_la_poutine", x: 150),
            tap("Suggestions pour vous", x: 210),
        ]
        let switcher: [TapPoint] = [
            tap("Votre story", x: 338), tap("festival_de_la_poutine", x: 355),
            tap("Suggestions pour vous", x: 369),
        ]
        let located = AppSwitcherCardLocator.locateCardX(
            appElements: app, switcherElements: switcher, windowWidth: 410)
        XCTAssertNotNil(located, "Rich multi-line overlap must still locate the card")
        XCTAssertEqual(located ?? -1, 355, accuracy: 1.0)
    }

    // MARK: - Label band

    func testLabelBandContainsExactAppName() {
        let elements = [
            tap("Instagram", x: 169, y: 145),
            tap("Votre story", x: 338, y: 309),
        ]
        XCTAssertTrue(AppSwitcherCardLocator.labelBandContains(
            appName: "Instagram", switcherElements: elements, windowHeight: 898))
    }

    func testLabelBandMatchesTruncatedPrefix() {
        // Edge cards clip their labels ("Insta…" OCRs as "Insta").
        let elements = [tap("Insta", x: 380, y: 142)]
        XCTAssertTrue(AppSwitcherCardLocator.labelBandContains(
            appName: "Instagram", switcherElements: elements, windowHeight: 898))
    }

    func testLabelBandIgnoresContentZoneText() {
        // The app name appearing INSIDE a card's content (Instagram's own logo
        // wordmark at feed top renders around y=220 in the card preview) is not
        // a label — only the band above the cards counts.
        let elements = [tap("Instagram", x: 199, y: 223)]
        XCTAssertFalse(AppSwitcherCardLocator.labelBandContains(
            appName: "Instagram", switcherElements: elements, windowHeight: 898))
    }

    func testLabelBandRejectsOtherAppLabels() {
        let elements = [tap("La Presse", x: 169, y: 144), tap("Mail", x: 336, y: 143)]
        XCTAssertFalse(AppSwitcherCardLocator.labelBandContains(
            appName: "Instagram", switcherElements: elements, windowHeight: 898))
    }

    func testFailsClosedWhenTwoCardsMatchEqually() {
        // Two non-edge cards with equal distinctive overlap — indistinguishable,
        // so the locator must fail closed rather than drag-quit a guess.
        let app: [TapPoint] = [tap("Dashboard", x: 100), tap("Settings", x: 110)]
        let switcher: [TapPoint] = [
            tap("Dashboard", x: 180), tap("Settings", x: 185),
            tap("Dashboard", x: 320), tap("Settings", x: 325),
        ]
        XCTAssertNil(
            AppSwitcherCardLocator.locateCardX(
                appElements: app, switcherElements: switcher, windowWidth: 410
            ),
            "Two equally-matching cards must fail closed (never quit the wrong app)")
    }

    // MARK: - Label-first locate

    /// On-device 2026-10-31: Horloge relaunched warm onto a sheet whose card
    /// preview is clipped by the right edge, so only "Annuler" and "encore."
    /// match the foreground capture — two equal clusters, an ambiguous
    /// fingerprint. The switcher's label names the card.
    private let device = CGSize(width: 430, height: 942)

    private var clippedHorlogeApp: [TapPoint] {
        [tap("Annuler", x: 50), tap("Sommeil désormais", x: 215),
         tap("dans Santé", x: 215), tap("encore.", x: 243),
         tap("Configurer dans Santé", x: 215)]
    }

    private var clippedHorlogeSwitcher: [TapPoint] {
        [tap("Horloge", x: 321, y: 146), tap("Roblox", x: 154, y: 150),
         tap("Pour toi", x: 153, y: 219), tap("Annuler", x: 269, y: 225),
         tap("Sommeil désc", x: 347, y: 345), tap("dans Sant", x: 371, y: 374),
         tap("encore.", x: 380, y: 499), tap("Configurer dans Sa", x: 369, y: 709)]
    }

    func testClippedPreviewFingerprintIsAmbiguous() {
        XCTAssertNil(AppSwitcherCardLocator.locateCardX(
            appElements: clippedHorlogeApp, switcherElements: clippedHorlogeSwitcher,
            windowWidth: Double(device.width)))
    }

    func testLocateCardUsesLabelWhenPreviewIsClipped() {
        XCTAssertEqual(AppSwitcherCardLocator.locateCard(
            appName: "Horloge", appElements: clippedHorlogeApp,
            switcherElements: clippedHorlogeSwitcher, windowSize: device), 321)
    }

    func testLocateCardUsesFingerprintWhenNoLabelReads() {
        let app = [tap("Résumé", x: 92), tap("Entraînements", x: 107)]
        let switcher = [tap("Résumé", x: 300), tap("Entraînements", x: 310)]
        XCTAssertEqual(AppSwitcherCardLocator.locateCard(
            appName: "Santé", appElements: app, switcherElements: switcher,
            windowSize: device), 310)
    }

    func testLabelLocateIgnoresLeftSliverAndContentZone() {
        let switcher = [tap("Horloge", x: 40, y: 146), tap("Horloge", x: 300, y: 400)]
        XCTAssertNil(AppSwitcherCardLocator.locateCardXByLabel(
            appName: "Horloge", switcherElements: switcher, windowSize: device))
    }

    func testLabelLocateFailsClosedOnTwoMatchingLabels() {
        let switcher = [tap("Horl", x: 150, y: 146), tap("Horloge", x: 321, y: 146)]
        XCTAssertNil(AppSwitcherCardLocator.locateCardXByLabel(
            appName: "Horloge", switcherElements: switcher, windowSize: device))
    }
}
