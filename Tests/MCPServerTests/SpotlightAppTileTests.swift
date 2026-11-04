// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests SpotlightAppTile against Spotlight screens OCR'd on a real iPhone XR (French UI).
// ABOUTME: A tile is the app's name below an icon or in a row of tiles; history rows and prose do not count.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class SpotlightAppTileTests: XCTestCase {

    private func el(_ text: String, _ x: Double, _ y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.9)
    }

    private var icon: String { CoreMLElementDetector.iconLabel }

    /// Spotlight reopened holding "Horloge" (2026-10-30): typed keys are ignored here.
    private var heldQuery: [TapPoint] {
        [
            el("Meilleur résultat", 86, 107),
            el(icon, 81, 188), el(icon, 355, 189), el(icon, 262, 189), el(icon, 173, 197),
            el("Nouv. alarme", 260, 218), el("Chronomètre", 349, 218),
            el("Régler le", 169, 219), el("Horloge", 80, 219),
            el("Suggestions", 72, 284), el("Horloge", 100, 329), el(icon, 42, 330),
            el("Horloge", 134, 436), el(icon, 136, 438),
            el("Q Horloge - Ouvrir", 133, 874),
        ]
    }

    func testTheHeldTopHitIsTheTileToTap() {
        let tile = SpotlightAppTile.label(for: "Horloge", in: heldQuery)
        XCTAssertEqual(tile?.tapX, 80)
        XCTAssertEqual(tile?.tapY, 219)
    }

    /// A tap on the label does nothing on iOS 26; the icon above it opens the app.
    func testTheTapGoesIntoTheIconAboveTheLabel() throws {
        let tile = try XCTUnwrap(SpotlightAppTile.label(for: "Horloge", in: heldQuery))
        let point = SpotlightAppTile.tapPoint(for: tile)
        XCTAssertEqual(point.x, 80)
        XCTAssertEqual(point.y, 219 - SpotlightAppTile.iconTapLift)
    }

    func testATopHitWithAnUndetectedIconIsATileBesideItsShortcuts() {
        // 2026-11-01 13:35: the clock-face icon read as "11 12"; the shortcut
        // "Régler le" has its icon above it, and "Horloge" shares its baseline.
        let undetectedIcon = [
            el("Meilleur résultat", 86, 107), el(icon, 186, 110), el(icon, 379, 117),
            el(icon, 282, 117), el("11 12", 74, 117), el("5", 91, 193),
            el("Nouv. alarme", 259, 218), el("Chronomètre", 349, 218),
            el("Régler le", 169, 219), el("Horloge", 80, 219), el("minuteur", 170, 234),
            el("Suggestions", 72, 284), el("Horloge", 100, 329), el(icon, 109, 330),
            el(icon, 45, 331), el("Plus de détails", 349, 382), el("Horloge", 56, 384),
            el("Réglages", 60, 518), el("Horloge", 134, 570), el(icon, 146, 573),
            el("Q", 53, 872), el("Horloge - Ouvrir", 145, 874),
        ]
        XCTAssertEqual(SpotlightAppTile.label(for: "Horloge", in: undetectedIcon)?.tapY, 219)
    }

    func testASuggestionRowGlyphMarksNoTileBelowIt() {
        // 2026-11-01: the top hit's clock icon went undetected; the suggestion
        // row's glyph (41,331), beside its own "Horloge" (100,329), sat 53pt
        // above the "Horloge" section heading (56,384), which opens nothing.
        let undetectedTopHit = [
            el("Meilleur résultat", 86, 107), el(icon, 173, 113), el(icon, 265, 116),
            el("11 12", 74, 117), el("Horloge", 80, 219),
            el("Suggestions", 72, 284), el("Horloge", 100, 329), el(icon, 102, 330),
            el(icon, 41, 331), el("Plus de détails", 349, 382), el("Horloge", 56, 384),
        ]
        XCTAssertNil(SpotlightAppTile.label(for: "Horloge", in: undetectedTopHit))
    }

    func testAnIconDetectedAtTheCardEdgeStillMarksTheTile() {
        // Same top hit, icons detected 105pt above the label (2026-10-30 15:54).
        let cardEdge = [el(icon, 81, 114), el(icon, 172, 114), el("Horloge", 80, 219),
                        el("Horloge", 101, 329), el("Horloge", 134, 436)]
        XCTAssertEqual(SpotlightAppTile.label(for: "Horloge", in: cardEdge)?.tapY, 219)
    }

    func testCaseAndAccentsDoNotMatter() {
        XCTAssertNotNil(SpotlightAppTile.label(for: "  horloge ", in: heldQuery))
        let suggested = [el(icon, 169, 186), el("Réglages", 169, 219)]
        XCTAssertNotNil(SpotlightAppTile.label(for: "reglages", in: suggested))
    }

    func testAnotherAppsTileIsNotTapped() {
        XCTAssertNil(SpotlightAppTile.label(for: "Plans", in: heldQuery))
    }

    func testAHistoryRowIsNotATile() {
        // Idle Spotlight lists "Clock" under recent searches, its glyph beside the text.
        let idle = [el("Recherches récentes", 103, 325), el("Q", 40, 370), el("Clock", 92, 370),
                    el(icon, 43, 375), el(icon, 235, 374)]
        XCTAssertNil(SpotlightAppTile.label(for: "Clock", in: idle))
    }

    func testALabelWithNoIconAboveIsNotATile() {
        XCTAssertNil(SpotlightAppTile.label(for: "Horloge",
                                             in: [el("Horloge", 80, 219), el(icon, 81, 60)]))
        XCTAssertNil(SpotlightAppTile.label(for: "", in: heldQuery))
    }

    func testTheHighestTileWinsWhenSeveralShowTheApp() {
        let twice = [el(icon, 262, 290), el("Horloge", 262, 322), el(icon, 80, 186), el("Horloge", 80, 219)]
        XCTAssertEqual(SpotlightAppTile.label(for: "Horloge", in: twice)?.tapY, 219)
    }
}
