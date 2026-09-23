// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentDetector: grouping OCR elements into UI components.
// ABOUTME: Verifies row matching, zones, multi-row absorption, fallback, and matching behavior.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ComponentDetectorTests: XCTestCase {

    // MARK: - Helpers

    let screenHeight: Double = 890
    let definitions = ComponentCatalog.definitions

    func point(
        _ text: String, x: Double = 200, y: Double = 400
    ) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    func classifiedNav(
        _ text: String, x: Double = 200, y: Double = 400, hasChevron: Bool = false
    ) -> ClassifiedElement {
        ClassifiedElement(
            point: point(text, x: x, y: y),
            role: .navigation,
            hasChevronContext: hasChevron
        )
    }

    func classifiedInfo(
        _ text: String, x: Double = 200, y: Double = 400
    ) -> ClassifiedElement {
        ClassifiedElement(
            point: point(text, x: x, y: y),
            role: .info
        )
    }

    func classifiedDeco(
        _ text: String, x: Double = 200, y: Double = 400
    ) -> ClassifiedElement {
        ClassifiedElement(
            point: point(text, x: x, y: y),
            role: .decoration
        )
    }

    // MARK: - Table Row Detection

    func testDetectsTableRowWithChevron() {
        let classified = [
            classifiedNav("General", x: 100, y: 400, hasChevron: true),
            classifiedDeco(">", x: 370, y: 400),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )

        // Should detect a table-row-disclosure component
        let disclosureRows = components.filter { $0.kind == "table-row-disclosure" }
        XCTAssertEqual(disclosureRows.count, 1,
            "Should detect one table-row-disclosure component")
        guard let row = disclosureRows.first else { return }
        XCTAssertTrue(row.hasChevron)
        XCTAssertNotNil(row.tapTarget,
            "Disclosure row should have a tap target")
        XCTAssertEqual(row.tapTarget?.text, "General",
            "Tap target should be the navigation element, not the chevron")
        XCTAssertEqual(row.elements.count, 2,
            "Both label and chevron should be absorbed into the component")
    }

    func testDetectsMultipleTableRows() {
        let classified = [
            classifiedNav("General", x: 100, y: 300, hasChevron: true),
            classifiedDeco(">", x: 370, y: 300),
            classifiedNav("Privacy", x: 100, y: 380, hasChevron: true),
            classifiedDeco(">", x: 370, y: 380),
            classifiedNav("About", x: 100, y: 460, hasChevron: true),
            classifiedDeco(">", x: 370, y: 460),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )

        let disclosureRows = components.filter { $0.kind == "table-row-disclosure" }
        XCTAssertEqual(disclosureRows.count, 3,
            "Should detect three separate table-row-disclosure components")
    }

    // MARK: - Non-Clickable Components

    func testExplanationTextNotClickable() {
        let classified = [
            classifiedInfo(
                "This is a long explanation of the feature that helps users understand",
                x: 200, y: 400
            ),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )

        // All detected components for info text should not be clickable
        for component in components {
            if component.elements.allSatisfy({ $0.role == .info }) {
                XCTAssertNil(component.tapTarget,
                    "Info text component should not have a tap target")
            }
        }
    }

    // MARK: - Zone Detection

    func testNavBarZoneDetected() {
        // Elements in the top 12% of screen should match nav bar zone
        let classified = [
            classifiedNav("Settings", x: 200, y: 50),
        ]

        let rowProps = ComponentDetector.computeRowProperties(
            classified, screenHeight: screenHeight
        )

        XCTAssertEqual(rowProps.zone, .navBar,
            "Elements in top 12% should be in nav bar zone")
    }

    func testTabBarZoneDetected() {
        // Elements in the bottom 12% of screen should match tab bar zone
        let classified = [
            classifiedNav("Home", x: 100, y: 830),
        ]

        let rowProps = ComponentDetector.computeRowProperties(
            classified, screenHeight: screenHeight
        )

        XCTAssertEqual(rowProps.zone, .tabBar,
            "Elements in bottom 12% should be in tab bar zone")
    }

    func testContentZoneForMidScreenElements() {
        let classified = [
            classifiedNav("General", x: 100, y: 400),
        ]

        let rowProps = ComponentDetector.computeRowProperties(
            classified, screenHeight: screenHeight
        )

        XCTAssertEqual(rowProps.zone, .content,
            "Mid-screen elements should be in content zone")
    }

    // MARK: - Row Properties

    func testRowPropertiesDetectChevron() {
        let classified = [
            classifiedNav("General", x: 100, y: 400, hasChevron: true),
            classifiedDeco(">", x: 370, y: 400),
        ]

        let rowProps = ComponentDetector.computeRowProperties(
            classified, screenHeight: screenHeight
        )

        XCTAssertTrue(rowProps.hasChevron)
        XCTAssertEqual(rowProps.elementCount, 2)
    }

    func testRowPropertiesDetectNumericValue() {
        let classified = [
            classifiedInfo("12,4km", x: 200, y: 400),
        ]

        let rowProps = ComponentDetector.computeRowProperties(
            classified, screenHeight: screenHeight
        )

        XCTAssertTrue(rowProps.hasNumericValue,
            "Should detect numeric value in '12,4km'")
    }

    // MARK: - Multi-Row Absorption

    func testSummaryCardAbsorbsInfoBelow() {
        // Summary card with title + value, followed by info text within absorption range
        let classified = [
            classifiedNav("Distance", x: 100, y: 300),
            classifiedInfo("12,4km", x: 200, y: 300),
            classifiedInfo("marche et course", x: 200, y: 330),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )

        // The summary card or whatever matched should have absorbed the info text
        let multiElement = components.filter { $0.elements.count > 1 }
        XCTAssertFalse(multiElement.isEmpty,
            "Should have at least one multi-element component from absorption")
    }

    func testAbsorptionPreservesAnchorRowTapTarget() {
        // Anchor row: summary card title (nav) + numeric value at Y=300
        // Absorbed row: chart icons (nav-classified) at Y=370 (within 80pt)
        // The tap target must come from the anchor row, not absorbed icons.
        let classified = [
            classifiedNav("Pas", x: 70, y: 300),
            classifiedInfo("6 762 pas", x: 200, y: 300),
            classifiedNav("icon", x: 367, y: 370),
            classifiedNav("icon", x: 100, y: 370),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )

        // Find the component that absorbed the icons
        let absorbed = components.filter { $0.elements.count >= 3 }
        XCTAssertFalse(absorbed.isEmpty,
            "Summary card should absorb nearby elements")

        if let card = absorbed.first, let target = card.tapTarget {
            // Tap target must be from anchor row (Y=300), not absorbed icons (Y=370)
            XCTAssertEqual(target.tapY, 300,
                "Tap target should be from anchor row, not absorbed elements " +
                "(got Y=\(target.tapY))")
        }
    }

    // MARK: - Fallback Behavior

    func testUnmatchedNavigationWithChevronIsExplorable() {
        // Navigation element WITH chevron context remains explorable in fallback
        let classified = [
            classifiedNav("SomeUnusualElement", x: 200, y: 400, hasChevron: true),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: [],
            screenHeight: screenHeight
        )

        XCTAssertFalse(components.isEmpty,
            "Unmatched elements should create fallback components")
        XCTAssertEqual(components[0].kind, "unclassified")
        XCTAssertNotNil(components[0].tapTarget,
            "Unclassified nav+chevron fallback should be tappable")
        XCTAssertTrue(components[0].definition.exploration.explorable,
            "Unclassified nav+chevron fallback should be explorable")
    }

    func testUnmatchedNavigationWithoutChevronIsNotExplorable() {
        // Navigation role WITHOUT a chevron in the row is non-explorable in
        // fallback: without the chevron we have no positive signal that the
        // element is a navigation target, and explorers would burn taps on
        // article fragments, CTAs, and app recommendations otherwise. The
        // element is still classified (kind=unclassified, role-based
        // clickability preserved) but the explorer skips it.
        let classified = [
            classifiedNav("Commencer", x: 200, y: 400, hasChevron: false),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: [],
            screenHeight: screenHeight
        )

        XCTAssertEqual(components[0].kind, "unclassified")
        XCTAssertNil(components[0].tapTarget,
            "Nav-without-chevron fallback should not expose a tap target to the explorer")
        XCTAssertFalse(components[0].definition.exploration.explorable,
            "Nav-without-chevron fallback should not be explorable")
    }

    func testUnmatchedInfoElementNotClickable() {
        // Use empty definitions so fallback path is taken
        let classified = [
            classifiedInfo("Some info text", x: 200, y: 400),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: [],
            screenHeight: screenHeight
        )

        XCTAssertEqual(components[0].kind, "unclassified")
        for component in components {
            XCTAssertNil(component.tapTarget,
                "Info element fallback should not have a tap target")
        }
    }

    // MARK: - Matching

    func testBestMatchPrefersSpecificDefinition() {
        // Row with chevron should match table-row-disclosure, not generic list-item
        let rowProps = ComponentDetector.RowProperties(
            elementCount: 2,
            hasChevron: true,
            hasNumericValue: false,
            rowHeight: 5,
            topY: 400,
            bottomY: 405,
            zone: .content,
            hasStateIndicator: false,
            hasLongText: false,
            hasDismissButton: false,
            averageConfidence: 0.95,
            numericOnlyCount: 0,
            elementTexts: ["General", ">"]
        )

        let match = ComponentDetector.bestMatch(
            definitions: definitions,
            rowProps: rowProps
        )

        XCTAssertEqual(match?.name, "table-row-disclosure",
            "Row with chevron should match table-row-disclosure")
    }

    func testNoMatchForNavBarInContentZone() {
        // Navigation bar definition requires navBar zone, so content zone should not match
        let rowProps = ComponentDetector.RowProperties(
            elementCount: 2,
            hasChevron: false,
            hasNumericValue: false,
            rowHeight: 5,
            topY: 400,
            bottomY: 405,
            zone: .content,
            hasStateIndicator: false,
            hasLongText: false,
            hasDismissButton: false,
            averageConfidence: 0.95,
            numericOnlyCount: 0,
            elementTexts: ["Settings", "Back"]
        )

        let navBarDef = definitions.first { $0.name == "navigation-bar" }
        XCTAssertNotNil(navBarDef)

        // Verify navBar definition doesn't match content zone
        let match = ComponentDetector.bestMatch(
            definitions: [navBarDef!],
            rowProps: rowProps
        )

        XCTAssertNil(match,
            "Nav bar definition should not match content zone elements")
    }

}
