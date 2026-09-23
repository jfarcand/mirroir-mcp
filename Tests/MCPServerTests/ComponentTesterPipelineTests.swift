// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentTester chevron mode mismatch and detection pipeline view.
// ABOUTME: Uses the synthetic OCR helpers from ComponentTesterTests.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

extension ComponentTesterTests {

    // MARK: - Chevron Mode Mismatch

    func testExplainMismatchChevronRequired() {
        let definition = ComponentDefinition(
            name: "chevron-required",
            platform: "ios",
            description: "Requires chevron via mode.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: .required, minElements: 1, maxElements: 6,
                maxRowHeightPt: 60, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .content,
                minConfidence: nil, excludeNumericOnly: nil, textPattern: nil
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
            averageConfidence: 0.95, numericOnlyCount: 0,
            elementTexts: ["Distance", "12,4km"]
        )

        let reasons = ComponentTester.explainMismatch(
            definition: definition, rowProps: rowProps
        )

        XCTAssertTrue(reasons.contains { $0.contains("required but absent") },
            "Should explain that chevron is required but absent")
    }

    func testExplainMismatchChevronPreferredNoReason() {
        let definition = ComponentDefinition(
            name: "chevron-preferred",
            platform: "ios",
            description: "Prefers chevron via mode.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: .preferred, minElements: 1, maxElements: 6,
                maxRowHeightPt: 60, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .content,
                minConfidence: nil, excludeNumericOnly: nil, textPattern: nil
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
            averageConfidence: 0.95, numericOnlyCount: 0,
            elementTexts: ["Distance", "12,4km"]
        )

        let reasons = ComponentTester.explainMismatch(
            definition: definition, rowProps: rowProps
        )

        XCTAssertFalse(reasons.contains { $0.contains("chevron") },
            "Preferred mode should not report missing chevron as a mismatch reason")
    }

    // MARK: - Detection Pipeline View

    func testDiagnoseIncludesDetectionView() {
        let elements = [
            point("General", x: 100, y: 400),
            point(">", x: 370, y: 400),
        ]

        let allDefs = [disclosureDefinition]

        let report = ComponentTester.diagnose(
            definition: disclosureDefinition,
            elements: elements,
            screenHeight: screenHeight,
            allDefinitions: allDefs
        )

        XCTAssertTrue(report.contains("Detection Result (after absorption)"),
            "Report should include the detection pipeline view section")
        XCTAssertTrue(report.contains("component(s)"),
            "Detection view should show component count")
    }

    func testExplainMismatchReportsTextPattern() {
        let patternDefinition = ComponentDefinition(
            name: "pattern-test",
            platform: "ios",
            description: "Requires text pattern match.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 6,
                maxRowHeightPt: 60, hasNumericValue: nil, hasLongText: nil,
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
            averageConfidence: 0.9, numericOnlyCount: 0,
            elementTexts: ["Résumé", "Partage"]
        )

        let reasons = ComponentTester.explainMismatch(
            definition: patternDefinition, rowProps: rowProps
        )

        XCTAssertTrue(reasons.contains { $0.contains("text_pattern") },
            "Mismatch reasons should include text_pattern explanation")
    }
}
