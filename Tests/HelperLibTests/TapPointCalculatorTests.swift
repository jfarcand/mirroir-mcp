// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for TapPointCalculator smart tap-point offset algorithm.
// ABOUTME: Validates short label upward offset, gap detection, clamping, and edge cases.

import Testing
@testable import HelperLib

@Suite("TapPointCalculator")
struct TapPointCalculatorTests {

    /// Typical iPhone Mirroring window width in points.
    private let windowWidth: Double = 410.0

    /// Helper to create a RawTextElement with sensible defaults.
    private func element(
        text: String, tapX: Double = 100.0,
        textTopY: Double, textBottomY: Double,
        bboxWidth: Double = 50.0, confidence: Float = 0.9
    ) -> RawTextElement {
        RawTextElement(
            text: text, tapX: tapX,
            textTopY: textTopY, textBottomY: textBottomY,
            bboxWidth: bboxWidth, confidence: confidence
        )
    }

    // MARK: - Home screen icon labels

    @Test("all labels in same row get fixed 30pt upward offset")
    func homeScreenIconLabels() {
        // Simulate 4 app icon labels in a row, all with the same textTopY
        let elements = [
            element(text: "Météo", tapX: 54, textTopY: 150, textBottomY: 165),
            element(text: "Calendrier", tapX: 124, textTopY: 150, textBottomY: 165),
            element(text: "Photos", tapX: 194, textTopY: 150, textBottomY: 165),
            element(text: "Appareil", tapX: 264, textTopY: 150, textBottomY: 165),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results.count == 4)
        // All labels are in the same row with gap=150 from y=0 → all get 30pt offset
        for result in results {
            #expect(result.tapY == 120.0, "\(result.text) should be offset 30pt upward")
        }
    }

    @Test("icon rows in separate rows each get offset")
    func separateRows() {
        // Row 1 with 3 icons, then Row 2 with 3 icons — big gap between
        let elements = [
            element(text: "Météo", tapX: 54, textTopY: 150, textBottomY: 165),
            element(text: "Photos", tapX: 124, textTopY: 150, textBottomY: 165),
            element(text: "Horloge", tapX: 194, textTopY: 150, textBottomY: 165),
            element(text: "Livres", tapX: 54, textTopY: 300, textBottomY: 315),
            element(text: "Safari", tapX: 124, textTopY: 300, textBottomY: 315),
            element(text: "Musique", tapX: 194, textTopY: 300, textBottomY: 315),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results.count == 6)
        // Row 1: gap = 150 from y=0, isIconRow → fixed 30pt offset
        #expect(results[0].tapY == 120.0)
        // Row 2: gap = 300 - 165 = 135 > 50, isIconRow → fixed 30pt offset
        #expect(results[3].tapY == 270.0)
    }

    @Test("simulates real home screen with Calendar OCR text reducing gap")
    func homeScreenWithCalendarText() {
        // Calendar icon shows "13" inside it, OCR picks it up just above the label row.
        // "13" is a single-element row (not an icon row), so it uses text center.
        // The label row has only 2 elements (below iconRowMinLabels=3), and
        // the gap from "13" is small anyway, so labels also use text center.
        let elements = [
            element(text: "13", tapX: 194, textTopY: 118, textBottomY: 134),
            element(text: "Météo", tapX: 54, textTopY: 158, textBottomY: 170),
            element(text: "Calendrier", tapX: 194, textTopY: 158, textBottomY: 170),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results.count == 3)
        // "13": single-element row, not isIconRow → text center = (118+134)/2 = 126
        #expect(results[0].tapY == 126.0)
        // Both labels in same row: only 2 elements (not isIconRow) → text center
        #expect(results[1].tapY == 164.0, "Météo should use text center")
        #expect(results[2].tapY == 164.0, "Calendrier should use text center")
    }

    @Test("icon row bypasses single-element OCR fragments for gap calculation")
    func iconRowBypassesSingleElements() {
        // Home screen: status bar → Calendar "16" inside icon → 4 icon labels.
        // The single "16" shouldn't reduce the gap for the icon label row.
        let elements = [
            element(text: "15:37", tapX: 71, textTopY: 25, textBottomY: 37),
            element(text: "75", tapX: 354, textTopY: 27, textBottomY: 37),
            element(text: "16", tapX: 250, textTopY: 148, textBottomY: 165),
            element(text: "Météo", tapX: 68, textTopY: 188, textBottomY: 200),
            element(text: "Calendrier", tapX: 252, textTopY: 188, textBottomY: 200),
            element(text: "Livres", tapX: 340, textTopY: 188, textBottomY: 200),
            element(text: "Horloge", tapX: 159, textTopY: 188, textBottomY: 200),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        let meteo = results.first { $0.text == "Météo" }!
        #expect(meteo.tapY == 158.0, "Icon row should bypass single-element '16' for gap")
    }

    @Test("mixed row with short and long labels does not offset any element")
    func mixedRowNoOffset() {
        // Waze route screen: "Y aller" (7 chars) + "Partir plus tard" (16 chars) on
        // the same row. Because the row contains a non-short element, the entire row
        // is treated as regular content — no element gets offset.
        let elements = [
            element(text: "54 min", tapX: 63, textTopY: 639, textBottomY: 655),
            element(text: "Y aller", tapX: 299, textTopY: 829, textBottomY: 845),
            element(
                text: "Partir plus tard", tapX: 112, textTopY: 829, textBottomY: 845,
                bboxWidth: 120
            ),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        let yAller = results.first { $0.text == "Y aller" }!
        let partir = results.first { $0.text == "Partir plus tard" }!
        // Both should use text center since the row is mixed (16-char label is not short)
        #expect(yAller.tapY == 837.0, "Y aller should use text center in mixed row")
        #expect(partir.tapY == 837.0, "Partir plus tard should use text center in mixed row")
    }

    // MARK: - Full-width text (no offset)

    @Test("long text does not get offset regardless of gap")
    func fullWidthText() {
        let elements = [
            element(
                text: "This is a long sentence that spans the screen",
                textTopY: 200, textBottomY: 220,
                bboxWidth: 350 // >40% of 410
            ),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results.count == 1)
        #expect(results[0].tapY == 210.0, "Long text should use text center without offset")
    }

    @Test("short text wider than 40% of window does not get offset")
    func wideShortText() {
        // 10 chars but very wide bounding box
        let elements = [
            element(
                text: "WIDE TEXT!",
                textTopY: 200, textBottomY: 215,
                bboxWidth: 200 // 200/410 = ~49% > 40%
            ),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results.count == 1)
        #expect(results[0].tapY == 207.5, "Wide short text should use text center without offset")
    }

    // MARK: - Mixed content

    @Test("single short labels use text center even with large gap")
    func singleShortLabelsUseTextCenter() {
        // Settings-style layout: single short labels with section gaps between them.
        // Each label is alone in its row (not an icon grid) → uses text center.
        let elements = [
            element(text: "Settings", textTopY: 80, textBottomY: 95, bboxWidth: 60),
            element(
                text: "Notifications may include alerts, sounds, and badge icons",
                textTopY: 130, textBottomY: 150,
                bboxWidth: 380
            ),
            element(text: "Safari", textTopY: 250, textBottomY: 265, bboxWidth: 50),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results.count == 3)
        // "Settings": single-element row, not isIconRow → text center
        #expect(results[0].tapY == 87.5, "Single short label should use text center")
        // Long text: not a short label → uses text center
        #expect(results[1].tapY == 140.0, "Long text should use text center")
        // "Safari": single-element row, not isIconRow → text center
        #expect(results[2].tapY == 257.5, "Single short label should use text center")
    }

    // MARK: - Small gap (no offset)

    @Test("single short labels use text center regardless of gap")
    func smallGap() {
        let elements = [
            element(text: "Label A", textTopY: 100, textBottomY: 115),
            element(text: "Label B", textTopY: 120, textBottomY: 135),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results.count == 2)
        // "Label A": single-element row, not isIconRow → text center
        #expect(results[0].tapY == 107.5)
        // "Label B": single-element row, gap = 5 < 50 → text center
        #expect(results[1].tapY == 127.5, "Small gap should use text center")
    }

    // MARK: - First element at top of screen

    @Test("first element uses gap from y=0")
    func firstElementGap() {
        let elements = [
            element(text: "Clock", textTopY: 5, textBottomY: 20),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results.count == 1)
        // Gap from y=0 to textTopY=5 is 5 → < 50 → no offset, use text center
        #expect(results[0].tapY == 12.5, "Small gap from screen top should use text center")
    }

    @Test("single element with large gap uses text center (not icon row)")
    func firstElementLargeGap() {
        let elements = [
            element(text: "Photos", textTopY: 150, textBottomY: 165),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results.count == 1)
        // Single element, not isIconRow → text center = (150+165)/2 = 157.5
        #expect(results[0].tapY == 157.5)
    }

    // MARK: - Edge cases

    @Test("empty input returns empty output")
    func emptyInput() {
        let results = TapPointCalculator.computeTapPoints(
            elements: [], windowWidth: windowWidth
        )
        #expect(results.isEmpty)
    }

    @Test("tap Y is clamped to zero when icon row offset would go negative")
    func clampToZero() {
        // Icon row near top of screen where 30pt offset would go negative.
        // Need 3+ elements to form an icon row, with textTopY < 30.
        let elements = [
            element(text: "Header", textTopY: 0, textBottomY: 5, bboxWidth: 300),
            element(text: "App1", tapX: 54, textTopY: 60, textBottomY: 75),
            element(text: "App2", tapX: 124, textTopY: 60, textBottomY: 75),
            element(text: "App3", tapX: 194, textTopY: 60, textBottomY: 75),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )
        // "Header": wide text, no offset → text center = (0+5)/2 = 2.5
        #expect(results[0].tapY == 2.5)
        // Icon row: gap = 60 - 5 = 55 > 50, isIconRow → offset 30, tapY = 60 - 30 = 30
        #expect(results[1].tapY == 30.0, "Icon row should be offset when gap > 50")
    }

    @Test("icon row offset uses textTopY minus 30pt")
    func iconRowOffsetMath() {
        // Verify the exact offset calculation: tapY = textTopY - 30
        let elements = [
            element(text: "Abc", tapX: 54, textTopY: 80, textBottomY: 95),
            element(text: "Def", tapX: 124, textTopY: 80, textBottomY: 95),
            element(text: "Ghi", tapX: 194, textTopY: 80, textBottomY: 95),
        ]
        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )
        // Gap from y=0 = 80 > 50, isIconRow → offset 30 → tapY = 80 - 30 = 50
        #expect(results[0].tapY == 50.0, "Icon row should use textTopY - 30pt offset")
        #expect(results[1].tapY == 50.0)
        #expect(results[2].tapY == 50.0)
    }

    // MARK: - Confidence and coordinates passthrough

    @Test("confidence and tapX are preserved from input")
    func passthroughValues() {
        let elements = [
            element(
                text: "Test", tapX: 205.5,
                textTopY: 100, textBottomY: 115,
                bboxWidth: 40, confidence: 0.85
            ),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results.count == 1)
        #expect(results[0].tapX == 205.5, "tapX should pass through unchanged")
        #expect(results[0].confidence == 0.85, "confidence should pass through unchanged")
        #expect(results[0].text == "Test", "text should pass through unchanged")
    }

    // MARK: - Sorting

    @Test("elements are processed in top-to-bottom order regardless of input order")
    func sortingOrder() {
        // Provide elements in reverse order
        let elements = [
            element(text: "Bottom", tapX: 100, textTopY: 300, textBottomY: 315),
            element(text: "Top", tapX: 100, textTopY: 50, textBottomY: 65),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results.count == 2)
        // "Top" should be processed first (sorted by textTopY)
        #expect(results[0].text == "Top")
        #expect(results[1].text == "Bottom")
    }

    // MARK: - Boundary: exactly at threshold

    @Test("icon row with exactly 15-char labels gets offset")
    func exactMaxLabelLength() {
        // 15 chars exactly, 3 elements to form icon row
        let elements = [
            element(text: "123456789012345", tapX: 54, textTopY: 100, textBottomY: 115, bboxWidth: 80),
            element(text: "abcdefghijklmno", tapX: 124, textTopY: 100, textBottomY: 115, bboxWidth: 80),
            element(text: "ABCDEFGHIJKLMNO", tapX: 194, textTopY: 100, textBottomY: 115, bboxWidth: 80),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        // gap = 100 > 50, isIconRow (3 short labels) → fixed 30pt offset
        #expect(results[0].tapY == 70.0, "15-char labels in icon row should get offset")
    }

    @Test("label with 16 characters is not treated as short")
    func overMaxLabelLength() {
        // 16 chars
        let elements = [
            element(text: "1234567890123456", textTopY: 100, textBottomY: 115, bboxWidth: 80),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        #expect(results[0].tapY == 107.5, "16-char label should use text center")
    }

    @Test("gap of exactly 50 does not trigger offset")
    func exactMinGap() {
        // Two elements where gap is exactly 50 (the threshold)
        let elements = [
            element(text: "First", textTopY: 0, textBottomY: 10),
            element(text: "Second", textTopY: 60, textBottomY: 75),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        // "First": gap = 0, not > 50 → no offset, use text center = (0+10)/2 = 5.0
        #expect(results[0].tapY == 5.0)
        // "Second": gap = 60 - 10 = 50, not > 50 → no offset, use text center = (60+75)/2 = 67.5
        #expect(results[1].tapY == 67.5, "Gap exactly at threshold should use text center")
    }

    @Test("gap just above 50 triggers icon row offset")
    func justAboveMinGap() {
        // Previous wide text, then an icon row with gap just above threshold
        let elements = [
            element(text: "Header text", textTopY: 0, textBottomY: 10, bboxWidth: 300),
            element(text: "App1", tapX: 54, textTopY: 61, textBottomY: 76),
            element(text: "App2", tapX: 124, textTopY: 61, textBottomY: 76),
            element(text: "App3", tapX: 194, textTopY: 61, textBottomY: 76),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        // "App1": gap = 61 - 10 = 51 > 50, isIconRow → offset 30 → tapY = 61 - 30 = 31
        #expect(results[1].tapY == 31.0, "Gap above threshold should trigger icon row offset")
    }

    // MARK: - Settings-style list items (regression test)

    @Test("Settings list items use text center despite section separator gaps")
    func settingsListItems() {
        // Réglages (Settings) layout: each list item is a single label in its row
        // with section separator gaps > 50pt between groups. These must NOT get
        // the icon offset, which would place the tap in the separator gap.
        let elements = [
            element(text: "Réglages", tapX: 206, textTopY: 80, textBottomY: 95, bboxWidth: 100),
            element(text: "Batterie", tapX: 86, textTopY: 605, textBottomY: 620, bboxWidth: 80),
            element(text: "Général", tapX: 104, textTopY: 695, textBottomY: 710, bboxWidth: 70),
            element(text: "Accessibilité", tapX: 105, textTopY: 750, textBottomY: 765, bboxWidth: 110),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth
        )

        let general = results.first { $0.text == "Général" }!
        // "Général" is a single-element row (not an icon row) → must use text center
        // Gap from "Batterie" = 695 - 620 = 75 > 50, but offset must NOT be applied
        #expect(general.tapY == 702.5, "Settings item should use text center, not icon offset")

        let batterie = results.first { $0.text == "Batterie" }!
        #expect(batterie.tapY == 612.5, "Settings item should use text center")
    }
}
