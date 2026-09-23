// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for TapPointCalculator pipeline stages, Settings-style lists, and the bottom zone.
// ABOUTME: Validates tab bar offsets and spacing uniformity detection.

import Testing
@testable import HelperLib

extension TapPointCalculatorTests {

    // MARK: - Pipeline stage tests

    @Test("groupIntoRows clusters elements within row tolerance")
    func groupIntoRowsClustering() {
        let sorted = [
            element(text: "A", tapX: 50, textTopY: 100, textBottomY: 115),
            element(text: "B", tapX: 150, textTopY: 102, textBottomY: 117),
            element(text: "C", tapX: 100, textTopY: 200, textBottomY: 215),
        ]
        let rows = TapPointCalculator.groupIntoRows(sorted)
        #expect(rows.count == 2, "A and B should be in same row, C in a separate row")
        #expect(rows[0].elements.count == 2)
        #expect(rows[1].elements.count == 1)
        #expect(rows[0].bottomY == 117.0)
        #expect(rows[1].bottomY == 215.0)
    }

    @Test("groupIntoRows returns empty for empty input")
    func groupIntoRowsEmpty() {
        let rows = TapPointCalculator.groupIntoRows([])
        #expect(rows.isEmpty)
    }

    @Test("classifyRows identifies icon rows vs regular rows")
    func classifyRowsIconDetection() {
        let iconElements = [
            element(text: "App1", tapX: 54, textTopY: 150, textBottomY: 165),
            element(text: "App2", tapX: 124, textTopY: 150, textBottomY: 165),
            element(text: "App3", tapX: 194, textTopY: 150, textBottomY: 165),
        ]
        let regularElements = [
            element(text: "Settings header text", tapX: 200, textTopY: 50, textBottomY: 65, bboxWidth: 300),
        ]
        let rows = [
            TapPointCalculator.Row(elements: regularElements, bottomY: 65),
            TapPointCalculator.Row(elements: iconElements, bottomY: 165),
        ]
        let classified = TapPointCalculator.classifyRows(rows, windowWidth: windowWidth, windowHeight: windowHeight)
        #expect(classified.count == 2)
        #expect(!classified[0].isIconRow, "Wide text row should not be icon row")
        #expect(classified[1].isIconRow, "3 short labels should be icon row")
        // Icon rows measure gap from previousMultiRowBottomY, which stays at 0
        // because the header is a single-element row (doesn't advance multi-row tracker).
        #expect(classified[1].gap == 150.0, "Icon row gap from y=0 (no prior multi-element row)")
    }

    @Test("applyOffsets uses text center for non-icon rows")
    func applyOffsetsRegularRow() {
        let elements = [
            element(text: "Label", tapX: 100, textTopY: 200, textBottomY: 220),
        ]
        let row = TapPointCalculator.Row(elements: elements, bottomY: 220)
        let classified = [TapPointCalculator.ClassifiedRow(row: row, isIconRow: false, gap: 100, isInBottomZone: false)]
        let points = TapPointCalculator.applyOffsets(classified)
        #expect(points.count == 1)
        #expect(points[0].tapY == 210.0, "Non-icon row should use text center")
    }

    @Test("applyOffsets applies icon offset when gap exceeds threshold")
    func applyOffsetsIconRow() {
        let elements = [
            element(text: "App1", tapX: 54, textTopY: 150, textBottomY: 165),
            element(text: "App2", tapX: 124, textTopY: 150, textBottomY: 165),
            element(text: "App3", tapX: 194, textTopY: 150, textBottomY: 165),
        ]
        let row = TapPointCalculator.Row(elements: elements, bottomY: 165)
        let classified = [TapPointCalculator.ClassifiedRow(row: row, isIconRow: true, gap: 80, isInBottomZone: false)]
        let points = TapPointCalculator.applyOffsets(classified)
        #expect(points.count == 3)
        for point in points {
            #expect(point.tapY == 120.0, "\(point.text) should get 30pt upward offset")
        }
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
            elements: elements, windowWidth: windowWidth, windowHeight: windowHeight
        )

        let general = results.first { $0.text == "Général" }!
        // "Général" is a single-element row (not an icon row) → must use text center
        // Gap from "Batterie" = 695 - 620 = 75 > 50, but offset must NOT be applied
        #expect(general.tapY == 702.5, "Settings item should use text center, not icon offset")

        let batterie = results.first { $0.text == "Batterie" }!
        #expect(batterie.tapY == 612.5, "Settings item should use text center")
    }

    // MARK: - Bottom zone (tab bar) tests

    @Test("tab bar gets same 30pt iconOffset via bottom zone")
    func tabBarGetsBottomZoneOffset() {
        // Reddit-style layout: two-column content at y=826, tab bar labels at y=856.
        // y=856 is in bottom zone (808.2). Bottom zone now uses the same iconOffset
        // (30pt) as regular icon rows. tapY = 856 - 30 = 826.
        let elements = [
            element(text: "Left col", tapX: 100, textTopY: 826, textBottomY: 840),
            element(text: "Right col", tapX: 300, textTopY: 826, textBottomY: 840),
            element(text: "Home", tapX: 56, textTopY: 856, textBottomY: 870),
            element(text: "Communities", tapX: 130, textTopY: 856, textBottomY: 870),
            element(text: "Create", tapX: 205, textTopY: 856, textBottomY: 870),
            element(text: "Chat", tapX: 280, textTopY: 856, textBottomY: 870),
            element(text: "Inbox", tapX: 355, textTopY: 856, textBottomY: 870),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth, windowHeight: windowHeight
        )

        let home = results.first { $0.text == "Home" }!
        // Bottom zone: iconOffset = 30. tapY = 856 - 30 = 826
        #expect(home.tapY == 826.0, "Tab bar should get 30pt iconOffset")

        let chat = results.first { $0.text == "Chat" }!
        #expect(chat.tapY == 826.0, "All tab bar labels should get same offset")
    }

    @Test("icon row mid-screen with small gap does not get offset")
    func midScreenSmallGapNoOffset() {
        // Same gap as tab bar test but at y=400 — not in bottom zone.
        // Need a multi-element row above so the icon row gap is measured correctly.
        // Gap = 400 - 384 = 16 < 50 threshold and not in bottom zone → no offset.
        let elements = [
            element(text: "Left col", tapX: 100, textTopY: 370, textBottomY: 384),
            element(text: "Right col", tapX: 300, textTopY: 370, textBottomY: 384),
            element(text: "Item1", tapX: 56, textTopY: 400, textBottomY: 414),
            element(text: "Item2", tapX: 130, textTopY: 400, textBottomY: 414),
            element(text: "Item3", tapX: 205, textTopY: 400, textBottomY: 414),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth, windowHeight: windowHeight
        )

        let item1 = results.first { $0.text == "Item1" }!
        // Not in bottom zone, gap = 400 - 384 = 16 < 50 → text center
        #expect(item1.tapY == 407.0, "Mid-screen icon row with small gap should use text center")
    }

    @Test("classifyRows sets isInBottomZone correctly")
    func classifyRowsBottomZone() {
        // Two icon rows: one mid-screen, one at bottom
        let midElements = [
            element(text: "App1", tapX: 54, textTopY: 150, textBottomY: 165),
            element(text: "App2", tapX: 124, textTopY: 150, textBottomY: 165),
            element(text: "App3", tapX: 194, textTopY: 150, textBottomY: 165),
        ]
        let bottomElements = [
            element(text: "Home", tapX: 56, textTopY: 856, textBottomY: 870),
            element(text: "Search", tapX: 130, textTopY: 856, textBottomY: 870),
            element(text: "Profile", tapX: 205, textTopY: 856, textBottomY: 870),
        ]
        let rows = [
            TapPointCalculator.Row(elements: midElements, bottomY: 165),
            TapPointCalculator.Row(elements: bottomElements, bottomY: 870),
        ]
        let classified = TapPointCalculator.classifyRows(
            rows, windowWidth: windowWidth, windowHeight: windowHeight
        )
        #expect(classified.count == 2)
        #expect(classified[0].isIconRow, "Mid-screen row should be icon row")
        #expect(!classified[0].isInBottomZone, "Mid-screen row should not be in bottom zone")
        #expect(classified[1].isIconRow, "Bottom row should be icon row")
        #expect(classified[1].isInBottomZone, "Bottom row should be in bottom zone")
    }

    @Test("bottom zone with exactly 3 labels gets iconOffset")
    func bottomZoneMinimumLabels() {
        // Minimum icon row count (3) at the bottom of the screen.
        // y=860 is in bottom zone (808.2). Uses iconOffset = 30. tapY = 860 - 30 = 830.
        let elements = [
            element(text: "Tab1", tapX: 100, textTopY: 860, textBottomY: 874),
            element(text: "Tab2", tapX: 205, textTopY: 860, textBottomY: 874),
            element(text: "Tab3", tapX: 310, textTopY: 860, textBottomY: 874),
        ]

        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth, windowHeight: windowHeight
        )

        // y=860 is in bottom zone. offset = 30 (iconOffset). tapY = 860 - 30 = 830.
        #expect(results[0].tapY == 830.0, "Bottom zone should get 30pt iconOffset")
    }

    @Test("applyOffsets uses iconOffset for bottom zone")
    func applyOffsetsBottomZone() {
        let elements = [
            element(text: "Home", tapX: 56, textTopY: 856, textBottomY: 870),
            element(text: "Search", tapX: 130, textTopY: 856, textBottomY: 870),
            element(text: "Profile", tapX: 205, textTopY: 856, textBottomY: 870),
        ]
        let row = TapPointCalculator.Row(elements: elements, bottomY: 870)
        // isInBottomZone=true, small gap — but bottom zone triggers offset regardless.
        // Uses iconOffset (30pt). tapY = 856 - 30 = 826.
        let classified = [TapPointCalculator.ClassifiedRow(
            row: row, isIconRow: true, gap: 30, isInBottomZone: true
        )]
        let points = TapPointCalculator.applyOffsets(classified)
        #expect(points.count == 3)
        for point in points {
            #expect(point.tapY == 826.0, "\(point.text) should get 30pt iconOffset")
        }
    }

    // MARK: - Spacing uniformity (issue #24: Chrome download bar)

    @Test("hasUniformSpacing accepts evenly spaced home-screen icon row")
    func uniformSpacingHomeRow() {
        // Real captured iOS home grid: x = 68, 159, 251, 340 → spacings 91/92/89.
        let elements = [
            element(text: "Météo", tapX: 68, textTopY: 195, textBottomY: 210),
            element(text: "Horloge", tapX: 159, textTopY: 195, textBottomY: 210),
            element(text: "Calendrier", tapX: 251, textTopY: 195, textBottomY: 210),
            element(text: "Livres", tapX: 340, textTopY: 195, textBottomY: 210),
        ]
        #expect(TapPointCalculator.hasUniformSpacing(elements) == true)
    }

    @Test("hasUniformSpacing rejects Chrome download bar (uneven spacing)")
    func nonUniformSpacingChromeDownloadBar() {
        // From issue #24: x = 54, 252, 298 → spacings 198/46 → ratio 4.30 > 1.5.
        let elements = [
            element(text: "· (1.9 MB)", tapX: 54, textTopY: 605, textBottomY: 620),
            element(text: "DOWNLOAD", tapX: 252, textTopY: 605, textBottomY: 620),
            element(text: "X", tapX: 298, textTopY: 605, textBottomY: 620),
        ]
        #expect(TapPointCalculator.hasUniformSpacing(elements) == false)
    }

    @Test("Chrome download bar gets text-center tapY (no upward offset)")
    func chromeDownloadBarTapYIsTextCenter() {
        // Issue #24 repro: row above is a long file name; row below is a
        // From: hostname. Heuristic used to flag this as an icon row and
        // shift tapY upward by 30pt — now blocked by the spacing check.
        let elements = [
            // Row above: long file name (single multi-element row not relevant here).
            element(text: "1731837266182378409.mp4", tapX: 114, textTopY: 619,
                    textBottomY: 635, bboxWidth: 220),
            // The button row — short labels, large gap above (~580pt from y=0
            // since file-name is the only thing between).
            element(text: "· (1.9 MB)", tapX: 54, textTopY: 605, textBottomY: 620,
                    bboxWidth: 65),
            element(text: "DOWNLOAD", tapX: 252, textTopY: 605, textBottomY: 620,
                    bboxWidth: 80),
            element(text: "X", tapX: 298, textTopY: 605, textBottomY: 620,
                    bboxWidth: 12),
        ]
        let results = TapPointCalculator.computeTapPoints(
            elements: elements, windowWidth: windowWidth, windowHeight: windowHeight
        )
        // DOWNLOAD's text center y = (605 + 620) / 2 = 612.5; without the
        // fix it would be 605 - 30 = 575 (above the button → tap misses).
        let download = results.first { $0.text == "DOWNLOAD" }
        #expect(download != nil)
        #expect(download?.tapY == 612.5,
                "DOWNLOAD should land on text center, not 30pt above")
    }

    @Test("hasUniformSpacing accepts 5-icon dock row")
    func uniformSpacingDockRow() {
        // Tab-bar / dock with 5 evenly-spaced icons (typical iOS home dock).
        let elements = [
            element(text: "A", tapX: 41, textTopY: 840, textBottomY: 855),
            element(text: "B", tapX: 125, textTopY: 840, textBottomY: 855),
            element(text: "C", tapX: 209, textTopY: 840, textBottomY: 855),
            element(text: "D", tapX: 292, textTopY: 840, textBottomY: 855),
            element(text: "E", tapX: 377, textTopY: 840, textBottomY: 855),
        ]
        #expect(TapPointCalculator.hasUniformSpacing(elements) == true)
    }

    @Test("hasUniformSpacing tolerates minor jitter from OCR")
    func uniformSpacingWithJitter() {
        // Real-world icon grid OCR centers may shift a few px; 83/98/91
        // ratio 1.18 — still under the 1.5 threshold.
        let elements = [
            element(text: "Mail", tapX: 69, textTopY: 392, textBottomY: 405),
            element(text: "Doodga", tapX: 152, textTopY: 392, textBottomY: 405),
            element(text: "Localiser", tapX: 250, textTopY: 392, textBottomY: 405),
            element(text: "Snapchat", tapX: 341, textTopY: 392, textBottomY: 405),
        ]
        #expect(TapPointCalculator.hasUniformSpacing(elements) == true)
    }

    @Test("hasUniformSpacing returns true for fewer than 3 elements")
    func uniformSpacingTrivialRow() {
        // <3 elements never reach the icon-row classification anyway.
        let two = [
            element(text: "A", tapX: 50, textTopY: 100, textBottomY: 115),
            element(text: "B", tapX: 200, textTopY: 100, textBottomY: 115),
        ]
        #expect(TapPointCalculator.hasUniformSpacing(two) == true)
    }
}
