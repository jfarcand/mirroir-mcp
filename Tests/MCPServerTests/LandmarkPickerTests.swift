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
// ABOUTME: Unit tests for LandmarkPicker: OCR element filtering and landmark selection.
// ABOUTME: Covers status bar filtering, time patterns, bare numbers, confidence, and header zone preference.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class LandmarkPickerTests: XCTestCase {

    // MARK: - pickLandmark

    func testPickLandmark() {
        let elements = [
            TapPoint(text: "Privacy & Security", tapX: 205, tapY: 400, confidence: 0.93),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Settings",
            "Should pick element in header zone")
    }

    func testPickLandmarkEmpty() {
        let landmark = LandmarkPicker.pickLandmark(from: [])
        XCTAssertNil(landmark, "Empty elements should return nil")
    }

    func testPickLandmarkFiltersShortText() {
        let elements = [
            TapPoint(text: "OK", tapX: 205, tapY: 120, confidence: 0.99),
            TapPoint(text: "Cancel Button", tapX: 205, tapY: 150, confidence: 0.90),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Cancel Button",
            "Should skip elements shorter than 3 chars")
    }

    func testPickLandmarkFiltersLowConfidence() {
        let elements = [
            TapPoint(text: "Fuzzy Match", tapX: 205, tapY: 120, confidence: 0.3),
            TapPoint(text: "Clear Text", tapX: 205, tapY: 150, confidence: 0.85),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Clear Text",
            "Should skip elements with confidence below threshold")
    }

    func testPickLandmarkFiltersLongText() {
        let longText = String(repeating: "A", count: 50)
        let elements = [
            TapPoint(text: longText, tapX: 205, tapY: 120, confidence: 0.95),
            TapPoint(text: "Reasonable Label", tapX: 205, tapY: 150, confidence: 0.90),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Reasonable Label",
            "Should skip elements longer than 40 chars")
    }

    func testPickLandmarkFiltersStatusBar() {
        let elements = [
            TapPoint(text: "12:25", tapX: 100, tapY: 20, confidence: 0.99),
            TapPoint(text: "Settings", tapX: 205, tapY: 30, confidence: 0.98),
            TapPoint(text: "100", tapX: 350, tapY: 20, confidence: 0.97),
            TapPoint(text: "General", tapX: 205, tapY: 200, confidence: 0.95),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "General",
            "Should skip status bar elements (tapY < 80)")
    }

    func testPickLandmarkFiltersTimePatterns() {
        let elements = [
            TapPoint(text: "12:251", tapX: 100, tapY: 120, confidence: 0.99),
            TapPoint(text: "9:41", tapX: 100, tapY: 130, confidence: 0.99),
            TapPoint(text: "Notes", tapX: 205, tapY: 200, confidence: 0.95),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Notes",
            "Should skip time-like patterns even outside status bar zone")
    }

    func testPickLandmarkFiltersBareNumbers() {
        let elements = [
            TapPoint(text: "100", tapX: 350, tapY: 120, confidence: 0.97),
            TapPoint(text: "55", tapX: 350, tapY: 130, confidence: 0.97),
            TapPoint(text: "App Title", tapX: 205, tapY: 200, confidence: 0.95),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "App Title",
            "Should skip bare numbers (battery %, signal)")
    }

    func testPickLandmarkPrefersHeaderZone() {
        let elements = [
            TapPoint(text: "Header Title", tapX: 205, tapY: 150, confidence: 0.90),
            TapPoint(text: "Bottom Item", tapX: 205, tapY: 500, confidence: 0.98),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Header Title",
            "Should prefer elements in 100-250pt header zone")
    }

    func testPickLandmarkFallsBackOutsideHeaderZone() {
        let elements = [
            TapPoint(text: "Deep Content", tapX: 205, tapY: 400, confidence: 0.90),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Deep Content",
            "Should fall back to topmost element when none in header zone")
    }

    // MARK: - isTimePattern / isBareNumber

    func testIsTimePattern() {
        XCTAssertTrue(LandmarkPicker.isTimePattern("12:25"))
        XCTAssertTrue(LandmarkPicker.isTimePattern("9:41"))
        XCTAssertTrue(LandmarkPicker.isTimePattern("12:251"))
        XCTAssertFalse(LandmarkPicker.isTimePattern("Settings"))
        XCTAssertFalse(LandmarkPicker.isTimePattern("12:25 PM"))
    }

    func testIsBareNumber() {
        XCTAssertTrue(LandmarkPicker.isBareNumber("100"))
        XCTAssertTrue(LandmarkPicker.isBareNumber("55"))
        XCTAssertTrue(LandmarkPicker.isBareNumber("5"))
        XCTAssertFalse(LandmarkPicker.isBareNumber("1234"))
        XCTAssertFalse(LandmarkPicker.isBareNumber("General"))
    }

    // MARK: - Structural Stability Tiering

    func testPrefersStructuralOverDynamic() {
        // "Feb 23" is a date pattern → fails structural filter
        // "Settings" passes structural filter and is in header zone
        let elements = [
            TapPoint(text: "Feb 23", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "Settings", tapX: 205, tapY: 150, confidence: 0.95),
            TapPoint(text: "Some dynamic text about today's weather forecast", tapX: 205, tapY: 300, confidence: 0.90),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Settings",
            "Should prefer structural element over date-pattern element in header zone")
    }

    func testFallsBackWhenNoStructural() {
        // All elements fail structural filter (dates, long text) except one that's too short
        // but still passes basic candidate filter
        let elements = [
            TapPoint(text: "Monday", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "Feb 23", tapX: 205, tapY: 150, confidence: 0.95),
            TapPoint(text: "Some content label", tapX: 205, tapY: 400, confidence: 0.90),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        // "Some content label" passes structural filter (not a date, not a number, reasonable length)
        // but "Monday" fails (date pattern), "Feb 23" fails (date pattern)
        XCTAssertEqual(landmark, "Some content label",
            "Should fall back to structural element outside header when no structural in header zone")
    }

    // MARK: - Stable Anchors / Excluded Patterns

    func testStableAnchorPreferredOverHeaderZoneText() {
        // "POLISHER" sits in the header zone (an ephemeral feed caption); the tab
        // label "Recherche" at the bottom matches a declared stable anchor.
        let elements = [
            TapPoint(text: "POLISHER", tapX: 205, tapY: 150, confidence: 0.95),
            TapPoint(text: "Recherche", tapX: 142, tapY: 846, confidence: 0.92),
        ]

        let landmark = LandmarkPicker.pickLandmark(
            from: elements, stableAnchors: ["Accueil", "Recherche"])
        XCTAssertEqual(landmark, "Recherche",
            "Declared stable anchor should beat ephemeral header-zone text")
    }

    func testNavBarTitleTierUsedWhenNoAnchorVisible() {
        // "Edit" is topmost in the header zone (would win Tier 1), but the nav
        // bar title tier picks the longest header-zone text instead.
        let elements = [
            TapPoint(text: "Edit", tapX: 60, tapY: 130, confidence: 0.95),
            TapPoint(text: "Notifications Center", tapX: 205, tapY: 180, confidence: 0.96),
            TapPoint(text: "Feed caption text", tapX: 205, tapY: 400, confidence: 0.90),
        ]

        let landmark = LandmarkPicker.pickLandmark(
            from: elements, stableAnchors: ["Accueil", "Recherche"])
        XCTAssertEqual(landmark, "Notifications Center",
            "Nav bar title tier should fire when no stable anchor is visible")
    }

    func testRequireStableReturnsNilOnFeedOnlyScreen() {
        // Only feed-zone content: no anchor match, no header-zone nav bar title.
        let elements = [
            TapPoint(text: "Amazing sunset over the bridge", tapX: 205, tapY: 320, confidence: 0.90),
            TapPoint(text: "Feed caption text", tapX: 205, tapY: 480, confidence: 0.88),
        ]

        let landmark = LandmarkPicker.pickLandmark(
            from: elements, stableAnchors: ["Accueil", "Recherche"], requireStable: true)
        XCTAssertNil(landmark,
            "requireStable should return nil when no stable tier matches")
    }

    func testExcludedPatternsNeverPicked() {
        // "POLISHER Post" would win Tier 1 (structural, header zone) but matches
        // an excluded pattern; the picker falls through to the next tier.
        let elements = [
            TapPoint(text: "POLISHER Post", tapX: 205, tapY: 150, confidence: 0.95),
            TapPoint(text: "Feed Item Label", tapX: 205, tapY: 400, confidence: 0.90),
        ]

        let landmark = LandmarkPicker.pickLandmark(
            from: elements, excludedPatterns: ["polisher"])
        XCTAssertEqual(landmark, "Feed Item Label",
            "Candidates matching an excluded pattern should never be picked")
    }

    func testAnchorSubstringInsideCaptionNotMatched() {
        // "Home" is a substring of the caption, but the tab label itself is not
        // on screen: Tier 0 must not match, and requireStable must return nil
        // instead of emitting a wait step that fails on replay.
        let elements = [
            TapPoint(text: "Homemade granola bars", tapX: 205, tapY: 320, confidence: 0.92),
        ]

        let landmark = LandmarkPicker.pickLandmark(
            from: elements, stableAnchors: ["Home", "Search"], requireStable: true)
        XCTAssertNil(landmark,
            "An anchor substring inside feed content must not match Tier 0")
    }

    func testWholeTextAnchorMatchReturnsDeclaredAnchor() {
        // The caption still contains "Home" as a substring, but the real tab
        // label is also visible — only the whole-text match wins Tier 0.
        let elements = [
            TapPoint(text: "Homemade granola bars", tapX: 205, tapY: 320, confidence: 0.92),
            TapPoint(text: "Home", tapX: 41, tapY: 846, confidence: 0.93),
        ]

        let landmark = LandmarkPicker.pickLandmark(
            from: elements, stableAnchors: ["Home", "Search"], requireStable: true)
        XCTAssertEqual(landmark, "Home",
            "The tab label's own whole text should match Tier 0")
    }

    func testBackChevronNeverPickedAsLandmark() {
        // "< Back" renders on every detail screen — even when it is the longest
        // header-zone text, the nav-bar-title tier must return the real title.
        let elements = [
            TapPoint(text: "< Back", tapX: 60, tapY: 145, confidence: 0.97),
            TapPoint(text: "Mode", tapX: 205, tapY: 190, confidence: 0.96),
        ]

        let landmark = LandmarkPicker.pickLandmark(
            from: elements, stableAnchors: [], requireStable: true)
        XCTAssertEqual(landmark, "Mode",
            "Back-navigation chrome must not shadow the nav bar title")
    }

    func testLoneChevronExcludedFromDefaultLadder() {
        // The all-default ladder must also refuse chevron chrome: with only a
        // chevron and content text visible, the pick falls to the content.
        let elements = [
            TapPoint(text: "< Back", tapX: 60, tapY: 145, confidence: 0.97),
            TapPoint(text: "Daily Average", tapX: 205, tapY: 400, confidence: 0.92),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Daily Average",
            "Chevron chrome is not a landmark in the default ladder either")
    }

    func testDefaultCallKeepsOriginalTierLadder() {
        // Same fixture as testNavBarTitleTierUsedWhenNoAnchorVisible but with
        // all-default arguments: the stable tiers (0/0.5) must not run, so the
        // pick is the original Tier 1 result ("Edit", topmost structural header
        // candidate) — labeled-app landmark selection is unchanged.
        let elements = [
            TapPoint(text: "Edit", tapX: 60, tapY: 130, confidence: 0.95),
            TapPoint(text: "Notifications Center", tapX: 205, tapY: 180, confidence: 0.96),
            TapPoint(text: "Feed caption text", tapX: 205, tapY: 400, confidence: 0.90),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Edit",
            "All-default calls must not route through the nav-bar-title tier")
    }
}
