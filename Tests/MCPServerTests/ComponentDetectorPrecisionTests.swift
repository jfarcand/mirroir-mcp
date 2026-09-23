// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentDetector precision rules.
// ABOUTME: Verifies that precision rules constrain which OCR rows match a component.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

extension ComponentDetectorTests {

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

    func testUnclassifiedNavWithChevronFallbackIsExplorable() {
        // Navigation+chevron elements keep their explorability in fallback,
        // so the component path doesn't lose real navigation targets.
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
            "Navigation+chevron fallback should have a tap target")
        XCTAssertTrue(components[0].definition.interaction.clickable,
            "Navigation+chevron fallback should be clickable")
        XCTAssertTrue(components[0].definition.exploration.explorable,
            "Navigation+chevron fallback should be explorable")
    }
}
