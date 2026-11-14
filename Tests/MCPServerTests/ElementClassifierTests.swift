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
// ABOUTME: Unit tests for ElementClassifier: role classification using text patterns and spatial proximity.
// ABOUTME: Verifies chevron/toggle detection, row grouping, destructive/info filtering, and full screen classification.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ElementClassifierTests: XCTestCase {

    // MARK: - Helpers

    private func point(_ text: String, x: Double = 205, y: Double = 200) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    private func classify(_ elements: [TapPoint]) -> [ClassifiedElement] {
        ElementClassifier.classify(elements)
    }

    private func role(of text: String, in classified: [ClassifiedElement]) -> ElementRole? {
        classified.first { $0.point.text == text }?.role
    }

    // MARK: - Decoration

    func testChevronIsDecoration() {
        let elements = [point(">", x: 370, y: 250)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .decoration)
    }

    func testRightChevronVariantsAreDecoration() {
        for chevron in [">", "\u{203A}", "\u{276F}"] {
            let result = classify([point(chevron)])
            XCTAssertEqual(result.first?.role, .decoration,
                "'\(chevron)' should be decoration")
        }
    }

    func testPunctuationOnlyIsDecoration() {
        let elements = [point("...", x: 205, y: 200)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .decoration)
    }

    func testShortTextIsDecoration() {
        // Under 3 characters (landmarkMinLength)
        let elements = [point("OK", x: 205, y: 200)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .decoration)
    }

    // MARK: - Destructive

    func testDestructiveTextIsDestructive() {
        let elements = [point("Sign Out", x: 205, y: 300)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .destructive)
    }

    func testDeleteIsDestructive() {
        let elements = [point("Delete All Data", x: 205, y: 300)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .destructive)
    }

    // MARK: - Info

    func testValuePatternIsInfo() {
        let values = ["3.2 GB", "50%", "128 MB", "1.5 TB", "256 KB"]
        for value in values {
            let result = classify([point(value)])
            XCTAssertEqual(result.first?.role, .info,
                "'\(value)' should be info")
        }
    }

    func testStateIndicatorIsInfo() {
        let indicators = ["On", "Off", "Connected", "None", "Auto"]
        for indicator in indicators {
            let result = classify([point(indicator)])
            XCTAssertEqual(result.first?.role, .info,
                "'\(indicator)' should be info")
        }
    }

    // MARK: - Navigation (with chevron context)

    func testLabelWithChevronIsNavigation() {
        let elements = [
            point("General", x: 100, y: 250),
            point(">", x: 370, y: 250),
        ]
        let result = classify(elements)
        XCTAssertEqual(role(of: "General", in: result), .navigation)
        XCTAssertEqual(role(of: ">", in: result), .decoration)
    }

    // MARK: - State Change (with toggle context)

    func testLabelWithStateIndicatorIsStateChange() {
        let elements = [
            point("Wi-Fi", x: 100, y: 300),
            point("On", x: 370, y: 300),
        ]
        let result = classify(elements)
        XCTAssertEqual(role(of: "Wi-Fi", in: result), .stateChange)
        XCTAssertEqual(role(of: "On", in: result), .info)
    }

    func testLabelWithOffIsStateChange() {
        let elements = [
            point("Bluetooth", x: 100, y: 300),
            point("Off", x: 370, y: 300),
        ]
        let result = classify(elements)
        XCTAssertEqual(role(of: "Bluetooth", in: result), .stateChange)
        XCTAssertEqual(role(of: "Off", in: result), .info)
    }

    // MARK: - Fallback

    func testLabelAloneIsNavigationFallback() {
        // Standalone "About" with no chevron or toggle context defaults to navigation
        let elements = [point("About", x: 205, y: 400)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .navigation)
    }

    // MARK: - Row Grouping

    func testRowGroupingByProximity() {
        let elements = [
            point("Row1A", x: 100, y: 100),
            point("Row1B", x: 300, y: 108),  // within 15pt
            point("Row2A", x: 100, y: 200),
            point("Row2B", x: 300, y: 212),  // within 15pt
        ]
        let rows = ElementClassifier.groupIntoRows(elements)
        XCTAssertEqual(rows.count, 2, "Should group into 2 rows")
        XCTAssertEqual(rows[0].count, 2, "First row should have 2 elements")
        XCTAssertEqual(rows[1].count, 2, "Second row should have 2 elements")
    }

    func testRowGroupingEmptyElements() {
        let rows = ElementClassifier.groupIntoRows([])
        XCTAssertTrue(rows.isEmpty)
    }

    func testRowGroupingCustomTolerance() {
        let elements = [
            point("A", x: 100, y: 100),
            point("B", x: 200, y: 120),  // 20pt apart
        ]
        // Default tolerance (15pt) should create 2 rows
        let tightRows = ElementClassifier.groupIntoRows(elements, tolerance: 15.0)
        XCTAssertEqual(tightRows.count, 2)

        // Wider tolerance should group them
        let wideRows = ElementClassifier.groupIntoRows(elements, tolerance: 25.0)
        XCTAssertEqual(wideRows.count, 1)
    }

    // MARK: - Toggle and Chevron on Different Rows

    func testToggleAndChevronOnDifferentRows() {
        // "Wi-Fi" + "On" on one row, "General" + ">" on another — no cross-contamination
        let elements = [
            point("Wi-Fi", x: 100, y: 200),
            point("On", x: 370, y: 200),
            point("General", x: 100, y: 300),
            point(">", x: 370, y: 300),
        ]
        let result = classify(elements)
        XCTAssertEqual(role(of: "Wi-Fi", in: result), .stateChange,
            "Wi-Fi should be stateChange (row has 'On')")
        XCTAssertEqual(role(of: "General", in: result), .navigation,
            "General should be navigation (row has '>')")
    }

    // MARK: - Full Settings Screen

    func testFullSettingsScreenClassification() {
        let elements = [
            // Apple ID row
            point("Jean-Francois", x: 200, y: 240),
            point(">", x: 370, y: 240),
            // Wi-Fi toggle row
            point("Wi-Fi", x: 100, y: 340),
            point("On", x: 370, y: 340),
            // Bluetooth toggle row
            point("Bluetooth", x: 100, y: 420),
            point("Off", x: 370, y: 420),
            // Navigation rows
            point("General", x: 100, y: 500),
            point(">", x: 370, y: 500),
            point("Privacy & Security", x: 100, y: 580),
            point(">", x: 370, y: 580),
            // Value row
            point("Storage", x: 100, y: 660),
            point("128 GB", x: 370, y: 660),
        ]

        let result = classify(elements)

        // Navigation targets (paired with ">")
        XCTAssertEqual(role(of: "Jean-Francois", in: result), .navigation)
        XCTAssertEqual(role(of: "General", in: result), .navigation)
        XCTAssertEqual(role(of: "Privacy & Security", in: result), .navigation)

        // Toggle rows (paired with On/Off)
        XCTAssertEqual(role(of: "Wi-Fi", in: result), .stateChange)
        XCTAssertEqual(role(of: "Bluetooth", in: result), .stateChange)

        // Info values
        XCTAssertEqual(role(of: "On", in: result), .info)
        XCTAssertEqual(role(of: "Off", in: result), .info)
        XCTAssertEqual(role(of: "128 GB", in: result), .info)

        // Decorations
        let chevrons = result.filter { $0.point.text == ">" }
        XCTAssertTrue(chevrons.allSatisfy { $0.role == .decoration })

        // Storage label is on a row with an info value but NOT a state indicator,
        // so it falls through to navigation (no chevron, not a toggle)
        XCTAssertEqual(role(of: "Storage", in: result), .navigation)
    }

    // MARK: - Element Order Preserved

    func testClassifiedOrderMatchesInput() {
        let elements = [
            point("General", x: 100, y: 500),
            point(">", x: 370, y: 500),
            point("Wi-Fi", x: 100, y: 200),
            point("On", x: 370, y: 200),
        ]
        let result = classify(elements)
        XCTAssertEqual(result.map(\.point.text), ["General", ">", "Wi-Fi", "On"],
            "Classified order should match input order")
    }

    // MARK: - Chevron Context

    func testChevronNavigationHasContext() {
        let elements = [
            point("General", x: 100, y: 250),
            point(">", x: 370, y: 250),
        ]
        let result = classify(elements)
        let general = result.first { $0.point.text == "General" }
        XCTAssertEqual(general?.role, .navigation)
        XCTAssertTrue(general?.hasChevronContext ?? false,
            "Navigation element paired with chevron should have hasChevronContext == true")
    }

    func testFallbackNavigationNoContext() {
        let elements = [point("About", x: 205, y: 400)]
        let result = classify(elements)
        let about = result.first { $0.point.text == "About" }
        XCTAssertEqual(about?.role, .navigation)
        XCTAssertFalse(about?.hasChevronContext ?? true,
            "Fallback navigation without chevron should have hasChevronContext == false")
    }

    func testLongLabelWithChevronStaysNavigation() {
        // "Your Account" is a long-ish label, but paired with ">" should still be .navigation
        let elements = [
            point("Your Account", x: 100, y: 300),
            point(">", x: 370, y: 300),
        ]
        let result = classify(elements)
        let account = result.first { $0.point.text == "Your Account" }
        XCTAssertEqual(account?.role, .navigation,
            "Long label with chevron should remain navigation")
        XCTAssertTrue(account?.hasChevronContext ?? false)
    }

    // MARK: - New Filters (steps 6b, 6c, 6d)

    func testLongTextIsInfo() {
        // > 50 chars, no row context -> should be classified as .info
        let longText = "This is a very long descriptive text that explains something in detail here"
        XCTAssertGreaterThan(longText.count, 50)
        let elements = [point(longText, x: 200, y: 300)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .info,
            "Text > 50 chars without row context should be .info")
    }

    func testSentenceLikeIsInfo() {
        let elements = [point("Photos, videos, and backups", x: 200, y: 300)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .info,
            "Sentence-like text (comma + conjunction) should be .info")
    }

    func testSentenceLikeFrenchIsInfo() {
        let elements = [point("Compte, iCloud, et achats", x: 200, y: 300)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .info,
            "French sentence-like text (comma + 'et') should be .info")
    }

    func testHelpLinkIsInfo() {
        let elements = [point("Learn More about privacy", x: 200, y: 300)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .info,
            "'Learn More' text should be .info")
    }

    func testHelpLinkFrenchIsInfo() {
        let elements = [point("En savoir plus sur la confidentialite", x: 200, y: 300)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .info,
            "'En savoir plus' text should be .info")
    }

    func testShortLabelWithoutContextRemainsNavigation() {
        // Short label, no chevron, no sentence/help patterns -> fallback navigation
        let elements = [point("General", x: 100, y: 300)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .navigation,
            "Short label without context should remain fallback navigation")
    }

    // MARK: - Time Patterns

    func testTimePatternIsInfo() {
        let elements = [point("15:02", x: 80, y: 200)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .info,
            "Time pattern '15:02' should be .info")
    }

    func testTimePatternWithOCRArtifactIsInfo() {
        // OCR sometimes appends an extra digit to the time
        let elements = [point("14:391", x: 80, y: 200)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .info,
            "Time pattern '14:391' (OCR artifact) should be .info")
    }

    func testSingleDigitHourTimeIsInfo() {
        let elements = [point("9:41", x: 80, y: 200)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .info,
            "Time pattern '9:41' should be .info")
    }

    // MARK: - Status Bar Zone

    func testStatusBarElementIsDecoration() {
        // Elements in the top 10% of the screen are status bar indicators
        let elements = [point("Slack", x: 200, y: 30)]
        let result = ElementClassifier.classify(elements, screenHeight: 898)
        XCTAssertEqual(result.first?.role, .decoration,
            "Element at y=30 in 898pt screen should be decoration (status bar zone)")
    }

    func testStatusBarZoneDisabledByDefault() {
        // Without screenHeight, the zone filter is disabled
        let elements = [point("Slack", x: 200, y: 30)]
        let result = classify(elements)
        XCTAssertEqual(result.first?.role, .navigation,
            "Without screenHeight, element at y=30 should fall through to navigation")
    }

    func testElementBelowStatusBarNotAffected() {
        let elements = [point("General", x: 200, y: 200)]
        let result = ElementClassifier.classify(elements, screenHeight: 898)
        XCTAssertEqual(result.first?.role, .navigation,
            "Element at y=200 should not be affected by status bar zone filter")
    }

    // MARK: - Paragraph Fragment Detection

    func testParagraphFragmentsReclassifiedAsInfo() {
        // 4 consecutive rows of paragraph text from Santé "Partage" screen
        let elements = [
            point("Tenez vos amis et vos proches au", x: 200, y: 300),
            point("courant de vos donnees de sante.", x: 200, y: 330),
            point("Les personnes avec qui vous partagez", x: 200, y: 360),
            point("peuvent consulter vos donnees dans Sante.", x: 200, y: 390),
        ]
        let result = classify(elements)

        for classified in result {
            XCTAssertEqual(classified.role, .info,
                "Paragraph line '\(classified.point.text)' should be reclassified as .info")
        }
    }

    func testSingleShortTextNotReclassified() {
        // One isolated multi-word line should remain navigation (not enough consecutive rows)
        let elements = [
            point("General", x: 100, y: 200),
            point(">", x: 370, y: 200),
            point("Some descriptive text here", x: 200, y: 300),
            point("Privacy", x: 100, y: 400),
            point(">", x: 370, y: 400),
        ]
        let result = classify(elements)
        XCTAssertEqual(role(of: "Some descriptive text here", in: result), .navigation,
            "Isolated multi-word line should stay as navigation fallback")
    }

    func testParagraphAdjacentToChevronRowNotAffected() {
        // Paragraph fragment rows interspersed with a chevron row:
        // the chevron row breaks the consecutive run
        let elements = [
            point("Some paragraph text line one", x: 200, y: 300),
            point("Some paragraph text line two", x: 200, y: 330),
            point("Settings Row", x: 100, y: 360),
            point(">", x: 370, y: 360),
            point("Some paragraph text line three", x: 200, y: 390),
        ]
        let result = classify(elements)

        // The chevron row breaks the run at 2 rows (below threshold of 3)
        XCTAssertEqual(role(of: "Some paragraph text line one", in: result), .navigation,
            "Fragment in run of 2 should stay navigation (below threshold)")
        XCTAssertEqual(role(of: "Settings Row", in: result), .navigation,
            "Chevron-context row should stay navigation")
    }

    func testParagraphRunExactlyThreeRows() {
        // Exactly 3 consecutive rows — minimum threshold, should reclassify
        let elements = [
            point("First line of paragraph text", x: 200, y: 300),
            point("Second line of paragraph text", x: 200, y: 330),
            point("Third line of paragraph text", x: 200, y: 360),
        ]
        let result = classify(elements)

        for classified in result {
            XCTAssertEqual(classified.role, .info,
                "3 consecutive paragraph lines should be reclassified as .info")
        }
    }

    func testSingleWordLinesNotTreatedAsParagraph() {
        // Single-word labels (no spaces) are not paragraph fragments
        let elements = [
            point("General", x: 200, y: 300),
            point("Privacy", x: 200, y: 330),
            point("About", x: 200, y: 360),
        ]
        let result = classify(elements)

        for classified in result {
            XCTAssertEqual(classified.role, .navigation,
                "Single-word lines should not be treated as paragraph fragments")
        }
    }
}
