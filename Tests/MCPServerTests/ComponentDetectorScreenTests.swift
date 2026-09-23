// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentDetector on whole screens: empty input, ordering, realistic layouts.
// ABOUTME: Covers the Health app screen, modal sheet detection, and split mode.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

extension ComponentDetectorTests {

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
        // Simulate a "Partager avec" (Share with) modal sheet header.
        // 4 elements distinguishes modal-sheet (max_elements: 4) from
        // article-modal (max_elements: 3) which has otherwise identical rules.
        let classified = [
            classifiedInfo("icon", x: 50, y: 150),
            classifiedNav("Partager avec", x: 150, y: 150),
            classifiedInfo("Contacts", x: 280, y: 150),
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
        // Test with unicode multiplication sign (✕), common in iOS.
        // 4 elements distinguishes modal-sheet (max_elements: 4) from
        // article-modal (max_elements: 3) which has otherwise identical rules.
        let classified = [
            classifiedInfo("icon", x: 50, y: 200),
            classifiedNav("Options", x: 150, y: 200),
            classifiedInfo("Paramètres", x: 280, y: 200),
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
}
