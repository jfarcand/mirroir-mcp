// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentDetector: grouping OCR elements into UI components.
// ABOUTME: Verifies row matching, multi-row absorption, zone detection, and fallback behavior.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ComponentDetectorTests: XCTestCase {

    // MARK: - Helpers

    private let screenHeight: Double = 890
    private let definitions = ComponentCatalog.definitions

    private func point(
        _ text: String, x: Double = 200, y: Double = 400
    ) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    private func classifiedNav(
        _ text: String, x: Double = 200, y: Double = 400, hasChevron: Bool = false
    ) -> ClassifiedElement {
        ClassifiedElement(
            point: point(text, x: x, y: y),
            role: .navigation,
            hasChevronContext: hasChevron
        )
    }

    private func classifiedInfo(
        _ text: String, x: Double = 200, y: Double = 400
    ) -> ClassifiedElement {
        ClassifiedElement(
            point: point(text, x: x, y: y),
            role: .info
        )
    }

    private func classifiedDeco(
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

    func testUnmatchedNavigationElementCreatesFallbackComponent() {
        // Use empty definitions so no definition can match — forces fallback path
        let classified = [
            classifiedNav("SomeUnusualElement", x: 200, y: 400),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: [],
            screenHeight: screenHeight
        )

        XCTAssertFalse(components.isEmpty,
            "Unmatched elements should create fallback components")
        XCTAssertEqual(components[0].kind, "unclassified")

        // Navigation elements preserve their explorability even when unmatched,
        // preventing the component path from losing elements the legacy path would tap.
        XCTAssertNotNil(components[0].tapTarget,
            "Unclassified nav fallback should be tappable")
        XCTAssertTrue(components[0].definition.exploration.explorable,
            "Unclassified nav fallback should be explorable")
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

    // MARK: - Empty Input

    func testEmptyClassifiedReturnsEmpty() {
        let components = ComponentDetector.detect(
            classified: [],
            definitions: definitions,
            screenHeight: screenHeight
        )

        XCTAssertTrue(components.isEmpty)
    }

    // MARK: - Sorted Output

    func testComponentsSortedByTopY() {
        let classified = [
            classifiedNav("Bottom", x: 100, y: 600, hasChevron: true),
            classifiedDeco(">", x: 370, y: 600),
            classifiedNav("Top", x: 100, y: 200, hasChevron: true),
            classifiedDeco(">", x: 370, y: 200),
            classifiedNav("Middle", x: 100, y: 400, hasChevron: true),
            classifiedDeco(">", x: 370, y: 400),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )

        // Components should be sorted by topY
        for i in 0..<(components.count - 1) {
            XCTAssertLessThanOrEqual(components[i].topY, components[i + 1].topY,
                "Components should be sorted by topY")
        }
    }

    // MARK: - Realistic Health App Screen

    func testHealthAppCardGrouping() {
        // Simulate the Health (Santé) app problem from the plan:
        // A single card "Distance (marche et course) / 12,4km" produces
        // 3-5 OCR elements. Component detection should group them.
        let elements = [
            TapPoint(text: "Distance", tapX: 50, tapY: 300, confidence: 0.9),
            TapPoint(text: "12,4", tapX: 200, tapY: 300, confidence: 0.9),
            TapPoint(text: "km", tapX: 240, tapY: 300, confidence: 0.9),
            TapPoint(text: "marche et course", tapX: 100, tapY: 330, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 315, confidence: 0.9),
        ]

        let classified = ElementClassifier.classify(
            elements, screenHeight: screenHeight
        )
        let components = ComponentDetector.detect(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )

        // Count clickable components — should be much fewer than raw elements
        let clickableComponents = components.filter { $0.tapTarget != nil }
        XCTAssertLessThan(clickableComponents.count, elements.count,
            "Component detection should reduce tap targets vs raw element count")
    }

    func testSettingsScreenGroupsRows() {
        // Simulate a Settings screen with typical iOS table rows
        let elements = [
            TapPoint(text: "General", tapX: 100, tapY: 300, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 300, confidence: 0.9),
            TapPoint(text: "Notifications", tapX: 100, tapY: 380, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 380, confidence: 0.9),
            TapPoint(text: "Privacy", tapX: 100, tapY: 460, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 460, confidence: 0.9),
        ]

        let classified = ElementClassifier.classify(
            elements, screenHeight: screenHeight
        )
        let components = ComponentDetector.detect(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )

        // Each row (label + chevron) should be one component
        let disclosureRows = components.filter { $0.kind == "table-row-disclosure" }
        XCTAssertEqual(disclosureRows.count, 3,
            "Each settings row with chevron should be detected as table-row-disclosure")

        // Each component should absorb both the label and the chevron
        for row in disclosureRows {
            XCTAssertEqual(row.elements.count, 2,
                "Disclosure row should absorb label + chevron")
        }

        // Tap targets should be the labels, not the chevrons
        let tapTexts = Set(disclosureRows.compactMap { $0.tapTarget?.text })
        XCTAssertTrue(tapTexts.contains("General"))
        XCTAssertTrue(tapTexts.contains("Notifications"))
        XCTAssertTrue(tapTexts.contains("Privacy"))
    }

    // MARK: - Modal Sheet Detection

    func testModalSheetDetectedByDismissButton() {
        // Simulate a "Partager avec" (Share with) modal sheet header
        let classified = [
            classifiedNav("Partager avec", x: 150, y: 150),
            classifiedDeco("X", x: 370, y: 150),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )

        let modalSheets = components.filter { $0.kind == "modal-sheet" }
        XCTAssertEqual(modalSheets.count, 1,
            "Should detect modal sheet from title + X dismiss button")
        guard let sheet = modalSheets.first else { return }

        XCTAssertNotNil(sheet.tapTarget,
            "Modal sheet should have a tap target (the dismiss button)")
        XCTAssertEqual(sheet.tapTarget?.text, "X",
            "Tap target should be the dismiss button, not the title")
        XCTAssertEqual(sheet.definition.interaction.clickResult, .dismisses)
    }

    func testRowPropertiesDetectDismissButton() {
        let classified = [
            classifiedNav("Share", x: 150, y: 300),
            classifiedDeco("X", x: 370, y: 300),
        ]

        let rowProps = ComponentDetector.computeRowProperties(
            classified, screenHeight: screenHeight
        )

        XCTAssertTrue(rowProps.hasDismissButton,
            "Row with X should have hasDismissButton = true")
    }

    func testRowWithoutDismissButtonFlagIsFalse() {
        let classified = [
            classifiedNav("General", x: 100, y: 400, hasChevron: true),
            classifiedDeco(">", x: 370, y: 400),
        ]

        let rowProps = ComponentDetector.computeRowProperties(
            classified, screenHeight: screenHeight
        )

        XCTAssertFalse(rowProps.hasDismissButton,
            "Row without dismiss button should have hasDismissButton = false")
    }

    func testModalSheetDismissTargetingWithUnicodeX() {
        // Test with unicode multiplication sign (×), common in iOS
        let classified = [
            classifiedNav("Options", x: 150, y: 200),
            classifiedDeco("✕", x: 370, y: 200),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )

        let modalSheets = components.filter { $0.kind == "modal-sheet" }
        XCTAssertEqual(modalSheets.count, 1,
            "Should detect modal sheet with unicode dismiss button")
        guard let sheet = modalSheets.first else { return }
        XCTAssertEqual(sheet.tapTarget?.text, "✕",
            "Tap target should be the unicode dismiss button")
    }

    // MARK: - Split Mode

    func testPerItemSplitCreatesOneComponentPerElement() {
        // Definition with split_mode: per_item, zone: tab_bar
        let tabItemDef = ComponentDefinition(
            name: "tab-bar-item",
            platform: "ios",
            description: "Tab bar item.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 6,
                maxRowHeightPt: 60, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .tabBar,
                minConfidence: nil, excludeNumericOnly: nil, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true, clickTarget: .firstText,
                clickResult: .switchesContext, backAfterClick: false,
                labelRule: .firstText
            ),
            exploration: ComponentExploration(
                explorable: true,
                role: .breadthNavigation,
                priority: .high
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: false, absorbsBelowWithinPt: 0, absorbCondition: .any,
                splitMode: .perItem
            )
        )

        // Three tab labels in the tab bar zone
        let elements = [
            classifiedNav("Résumé", x: 100, y: 850),
            classifiedNav("Partage", x: 200, y: 850),
            classifiedNav("Explorer", x: 300, y: 850)
        ]

        let result = ComponentDetector.detect(
            classified: elements, definitions: [tabItemDef],
            screenHeight: screenHeight
        )

        XCTAssertEqual(result.count, 3,
            "split_mode: per_item should create one component per element")
        XCTAssertTrue(result.allSatisfy { $0.kind == "tab-bar-item" })
        XCTAssertEqual(result[0].elements.count, 1)
        XCTAssertEqual(result[1].elements.count, 1)
        XCTAssertEqual(result[2].elements.count, 1)
    }

    func testPerItemSplitSkipsDecoration() {
        let tabItemDef = ComponentDefinition(
            name: "tab-bar-item",
            platform: "ios",
            description: "Tab bar item.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 6,
                maxRowHeightPt: 60, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .tabBar,
                minConfidence: nil, excludeNumericOnly: nil, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true, clickTarget: .firstText,
                clickResult: .switchesContext, backAfterClick: false,
                labelRule: .firstText
            ),
            exploration: ComponentExploration(
                explorable: true,
                role: .breadthNavigation,
                priority: .high
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: false, absorbsBelowWithinPt: 0, absorbCondition: .any,
                splitMode: .perItem
            )
        )

        // Two tab labels plus a decoration element
        let elements = [
            classifiedNav("Résumé", x: 100, y: 850),
            classifiedDeco("icon", x: 150, y: 850),
            classifiedNav("Explorer", x: 300, y: 850)
        ]

        let result = ComponentDetector.detect(
            classified: elements, definitions: [tabItemDef],
            screenHeight: screenHeight
        )

        XCTAssertEqual(result.count, 2,
            "split_mode: per_item should skip decoration elements")
        XCTAssertTrue(result.allSatisfy { $0.kind == "tab-bar-item" })
    }

    // MARK: - Precision Rules

    func testMinConfidenceRejectsLowConfidenceRow() {
        // Definition requires minConfidence=0.5, row has avg conf 0.3
        let definition = ComponentDefinition(
            name: "high-conf-only",
            platform: "ios",
            description: "Requires high confidence.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 4,
                maxRowHeightPt: 100, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .content,
                minConfidence: 0.5, excludeNumericOnly: nil, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true, clickTarget: .firstNavigation,
                clickResult: .pushesScreen, backAfterClick: true,
                labelRule: .tapTarget
            ),
            exploration: ComponentExploration(
                explorable: true,
                role: .depthNavigation,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true, absorbsBelowWithinPt: 0, absorbCondition: .any,
                splitMode: .none
            )
        )

        let rowProps = ComponentDetector.RowProperties(
            elementCount: 2, hasChevron: false, hasNumericValue: false,
            rowHeight: 5, topY: 400, bottomY: 405, zone: .content,
            hasStateIndicator: false, hasLongText: false, hasDismissButton: false,
            averageConfidence: 0.3, numericOnlyCount: 0,
            elementTexts: ["Résumé", "Partage"]
        )

        let match = ComponentDetector.bestMatch(
            definitions: [definition], rowProps: rowProps
        )
        XCTAssertNil(match, "Row with avg conf 0.3 should not match def requiring 0.5")
    }

    func testMinConfidenceAcceptsHighConfidenceRow() {
        let definition = ComponentDefinition(
            name: "high-conf-only",
            platform: "ios",
            description: "Requires high confidence.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 4,
                maxRowHeightPt: 100, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .content,
                minConfidence: 0.5, excludeNumericOnly: nil, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true, clickTarget: .firstNavigation,
                clickResult: .pushesScreen, backAfterClick: true,
                labelRule: .tapTarget
            ),
            exploration: ComponentExploration(
                explorable: true,
                role: .depthNavigation,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true, absorbsBelowWithinPt: 0, absorbCondition: .any,
                splitMode: .none
            )
        )

        let rowProps = ComponentDetector.RowProperties(
            elementCount: 2, hasChevron: false, hasNumericValue: false,
            rowHeight: 5, topY: 400, bottomY: 405, zone: .content,
            hasStateIndicator: false, hasLongText: false, hasDismissButton: false,
            averageConfidence: 0.9, numericOnlyCount: 0,
            elementTexts: ["Résumé", "Partage"]
        )

        let match = ComponentDetector.bestMatch(
            definitions: [definition], rowProps: rowProps
        )
        XCTAssertNotNil(match, "Row with avg conf 0.9 should match def requiring 0.5")
    }

    func testExcludeNumericOnlyReducesEffectiveCount() {
        // Row has 3 elements: "23", "Résumé", "Partage"
        // With exclude_numeric_only=true, effective count = 2
        // Definition requires max_elements=2 — passes with exclusion, would fail without
        let definition = ComponentDefinition(
            name: "no-numeric-noise",
            platform: "ios",
            description: "Excludes numeric-only elements.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 2,
                maxRowHeightPt: 100, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .tabBar,
                minConfidence: nil, excludeNumericOnly: true, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: false, clickTarget: .none,
                clickResult: .none, backAfterClick: false,
                labelRule: .tapTarget
            ),
            exploration: ComponentExploration(
                explorable: false,
                role: .info,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true, absorbsBelowWithinPt: 0, absorbCondition: .any,
                splitMode: .none
            )
        )

        let rowProps = ComponentDetector.RowProperties(
            elementCount: 3, hasChevron: false, hasNumericValue: false,
            rowHeight: 5, topY: 845, bottomY: 850, zone: .tabBar,
            hasStateIndicator: false, hasLongText: false, hasDismissButton: false,
            averageConfidence: 0.8, numericOnlyCount: 1,
            elementTexts: ["23", "Résumé", "Partage"]
        )

        let match = ComponentDetector.bestMatch(
            definitions: [definition], rowProps: rowProps
        )
        XCTAssertNotNil(match,
            "With exclude_numeric_only, effective count 2 fits max_elements=2")
    }

    func testTextPatternMatchesElement() {
        let definition = ComponentDefinition(
            name: "search-icon",
            platform: "ios",
            description: "Matches search icon (Q misread).",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 4,
                maxRowHeightPt: 100, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .tabBar,
                minConfidence: nil, excludeNumericOnly: nil, textPattern: "^[Qq]$"
            ),
            interaction: ComponentInteraction(
                clickable: false, clickTarget: .none,
                clickResult: .none, backAfterClick: false,
                labelRule: .tapTarget
            ),
            exploration: ComponentExploration(
                explorable: false,
                role: .info,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true, absorbsBelowWithinPt: 0, absorbCondition: .any,
                splitMode: .none
            )
        )

        let rowProps = ComponentDetector.RowProperties(
            elementCount: 2, hasChevron: false, hasNumericValue: false,
            rowHeight: 5, topY: 845, bottomY: 850, zone: .tabBar,
            hasStateIndicator: false, hasLongText: false, hasDismissButton: false,
            averageConfidence: 0.8, numericOnlyCount: 0,
            elementTexts: ["Q", "Rechercher"]
        )

        let match = ComponentDetector.bestMatch(
            definitions: [definition], rowProps: rowProps
        )
        XCTAssertNotNil(match, "Row with 'Q' should match text_pattern ^[Qq]$")
    }

    func testTextPatternRejectsNonMatching() {
        let definition = ComponentDefinition(
            name: "search-icon",
            platform: "ios",
            description: "Matches search icon (Q misread).",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 4,
                maxRowHeightPt: 100, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .tabBar,
                minConfidence: nil, excludeNumericOnly: nil, textPattern: "^[Qq]$"
            ),
            interaction: ComponentInteraction(
                clickable: false, clickTarget: .none,
                clickResult: .none, backAfterClick: false,
                labelRule: .tapTarget
            ),
            exploration: ComponentExploration(
                explorable: false,
                role: .info,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true, absorbsBelowWithinPt: 0, absorbCondition: .any,
                splitMode: .none
            )
        )

        let rowProps = ComponentDetector.RowProperties(
            elementCount: 2, hasChevron: false, hasNumericValue: false,
            rowHeight: 5, topY: 845, bottomY: 850, zone: .tabBar,
            hasStateIndicator: false, hasLongText: false, hasDismissButton: false,
            averageConfidence: 0.8, numericOnlyCount: 0,
            elementTexts: ["Résumé", "Partage"]
        )

        let match = ComponentDetector.bestMatch(
            definitions: [definition], rowProps: rowProps
        )
        XCTAssertNil(match,
            "Row without Q/q should not match text_pattern ^[Qq]$")
    }

    func testUnclassifiedNavFallbackIsExplorable() {
        // Navigation-role elements keep their explorability in fallback,
        // so the component path doesn't lose elements the legacy path would tap.
        let classified = [
            classifiedNav("SomeElement", x: 200, y: 400, hasChevron: true),
        ]

        let components = ComponentDetector.detect(
            classified: classified,
            definitions: [],
            screenHeight: screenHeight
        )

        XCTAssertEqual(components.count, 1)
        XCTAssertEqual(components[0].kind, "unclassified")
        XCTAssertNotNil(components[0].tapTarget,
            "Navigation fallback should have a tap target")
        XCTAssertTrue(components[0].definition.interaction.clickable,
            "Navigation fallback should be clickable")
        XCTAssertTrue(components[0].definition.exploration.explorable,
            "Navigation fallback should be explorable")
    }

    // MARK: - Post-Processing Absorption

    /// Helper to build a ScreenComponent with an absorbing definition for testing.
    private func makeAbsorbingComponent(
        kind: String, elements: [ClassifiedElement],
        absorbRange: Double, condition: AbsorbCondition = .any,
        clickable: Bool = true
    ) -> ScreenComponent {
        let def = ComponentDefinition(
            name: kind,
            platform: "ios",
            description: "Test absorbing component.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 10,
                maxRowHeightPt: 100, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .content,
                minConfidence: nil, excludeNumericOnly: nil, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: clickable, clickTarget: .firstNavigation,
                clickResult: .pushesScreen, backAfterClick: true,
                labelRule: .tapTarget
            ),
            exploration: ComponentExploration(
                explorable: clickable,
                role: clickable ? .depthNavigation : .info,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true, absorbsBelowWithinPt: absorbRange,
                absorbCondition: condition, splitMode: .none
            )
        )

        let ys = elements.map { $0.point.tapY }
        let topY = ys.min() ?? 0
        let bottomY = ys.max() ?? 0
        let tapTarget = elements.first(where: { $0.role == .navigation })?.point

        return ScreenComponent(
            kind: kind, definition: def, elements: elements,
            tapTarget: tapTarget,
            hasChevron: false, topY: topY, bottomY: bottomY
        )
    }

    /// Helper to build a simple non-absorbing component for testing.
    private func makeSimpleComponent(
        kind: String, elements: [ClassifiedElement], clickable: Bool = true
    ) -> ScreenComponent {
        return makeAbsorbingComponent(
            kind: kind, elements: elements, absorbRange: 0, clickable: clickable
        )
    }

    func testApplyAbsorptionMergesNearbyComponents() {
        // Summary card at y=280 with absorbs_below_within_pt=80
        let parent = makeAbsorbingComponent(
            kind: "summary-card",
            elements: [classifiedNav("Activité", x: 100, y: 280)],
            absorbRange: 80
        )
        // List item at y=335, within 80pt of parent's bottomY (280)
        let child = makeSimpleComponent(
            kind: "list-item",
            elements: [classifiedInfo("Bouger", x: 100, y: 335)]
        )

        let result = ComponentDetector.applyAbsorption([parent, child])

        XCTAssertEqual(result.count, 1,
            "Nearby component should be absorbed into the parent")
        XCTAssertEqual(result[0].elements.count, 2,
            "Merged component should contain both elements")
    }

    func testApplyAbsorptionSkipsBeyondRange() {
        // Summary card at y=100 with absorbs_below_within_pt=80
        let parent = makeAbsorbingComponent(
            kind: "summary-card",
            elements: [classifiedNav("Activité", x: 100, y: 100)],
            absorbRange: 80
        )
        // List item at y=250, beyond 80pt range (100 + 80 = 180 < 250)
        let distant = makeSimpleComponent(
            kind: "list-item",
            elements: [classifiedInfo("Loin", x: 100, y: 250)]
        )

        let result = ComponentDetector.applyAbsorption([parent, distant])

        XCTAssertEqual(result.count, 2,
            "Component beyond absorption range should stay separate")
    }

    func testApplyAbsorptionPreservesParentTapTarget() {
        let parent = makeAbsorbingComponent(
            kind: "summary-card",
            elements: [classifiedNav("Activité", x: 100, y: 280)],
            absorbRange: 80
        )
        let child = makeSimpleComponent(
            kind: "list-item",
            elements: [classifiedInfo("65 cal", x: 100, y: 330)]
        )

        let result = ComponentDetector.applyAbsorption([parent, child])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].tapTarget?.text, "Activité",
            "Merged component should keep the parent's tap target")
    }

    func testApplyAbsorptionRespectsCondition() {
        // Parent with infoOrDecorationOnly condition
        let parent = makeAbsorbingComponent(
            kind: "summary-card",
            elements: [classifiedNav("Activité", x: 100, y: 280)],
            absorbRange: 80,
            condition: .infoOrDecorationOnly
        )
        // Navigation element should NOT be absorbed (condition requires info/deco only)
        let navChild = makeSimpleComponent(
            kind: "list-item",
            elements: [classifiedNav("Détails", x: 100, y: 330)]
        )

        let result = ComponentDetector.applyAbsorption([parent, navChild])

        XCTAssertEqual(result.count, 2,
            "Navigation element should not be absorbed with infoOrDecorationOnly condition")
    }

    func testApplyAbsorptionAbsorbsInfoWithCondition() {
        // Same condition but with info-role elements — should absorb
        let parent = makeAbsorbingComponent(
            kind: "summary-card",
            elements: [classifiedNav("Activité", x: 100, y: 280)],
            absorbRange: 80,
            condition: .infoOrDecorationOnly
        )
        let infoChild = makeSimpleComponent(
            kind: "list-item",
            elements: [classifiedInfo("65 cal", x: 100, y: 330)]
        )

        let result = ComponentDetector.applyAbsorption([parent, infoChild])

        XCTAssertEqual(result.count, 1,
            "Info element should be absorbed with infoOrDecorationOnly condition")
    }

    func testApplyAbsorptionNoAbsorbWhenRangeZero() {
        // Both components have absorbRange=0 — no absorption
        let a = makeSimpleComponent(
            kind: "row-a",
            elements: [classifiedNav("First", x: 100, y: 300)]
        )
        let b = makeSimpleComponent(
            kind: "row-b",
            elements: [classifiedNav("Second", x: 100, y: 310)]
        )

        let result = ComponentDetector.applyAbsorption([a, b])

        XCTAssertEqual(result.count, 2,
            "Components with zero absorb range should not merge")
    }
}
