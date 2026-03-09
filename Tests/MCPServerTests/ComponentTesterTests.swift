// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentTester: validates component definition diagnostic reports.
// ABOUTME: Uses synthetic OCR data to test matching, mismatch explanation, and formatting.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ComponentTesterTests: XCTestCase {

    // MARK: - Helpers

    private let screenHeight: Double = 890

    private func point(
        _ text: String, x: Double = 200, y: Double = 400
    ) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    /// A tab-bar definition that matches elements in the bottom 12% of the screen.
    private var tabBarDefinition: ComponentDefinition {
        ComponentDefinition(
            name: "tab-bar-item",
            platform: "ios",
            description: "Tab bar item at bottom of screen.",
            visualPattern: ["Icon above label text"],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil,
                chevronMode: nil,
                minElements: 1,
                maxElements: 6,
                maxRowHeightPt: 60,
                hasNumericValue: nil,
                hasLongText: nil,
                hasDismissButton: nil,
                zone: .tabBar,
                minConfidence: nil,
                excludeNumericOnly: nil,
                textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: false,
                clickTarget: .none,
                clickResult: .none,
                backAfterClick: false,
                labelRule: .tapTarget
            ),
            exploration: ComponentExploration(
                explorable: false,
                role: .info,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true,
                absorbsBelowWithinPt: 0,
                absorbCondition: .any,
                splitMode: .none
            )
        )
    }

    /// A disclosure row definition that requires chevron in content zone.
    private var disclosureDefinition: ComponentDefinition {
        ComponentDefinition(
            name: "table-row-disclosure",
            platform: "ios",
            description: "Table row with chevron.",
            visualPattern: ["Label text ... >"],
            matchRules: ComponentMatchRules(
                rowHasChevron: true,
                chevronMode: nil,
                minElements: 2,
                maxElements: 6,
                maxRowHeightPt: 30,
                hasNumericValue: nil,
                hasLongText: nil,
                hasDismissButton: nil,
                zone: .content,
                minConfidence: nil,
                excludeNumericOnly: nil,
                textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true,
                clickTarget: .firstNavigation,
                clickResult: .pushesScreen,
                backAfterClick: true,
                labelRule: .tapTarget
            ),
            exploration: ComponentExploration(
                explorable: true,
                role: .depthNavigation,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true,
                absorbsBelowWithinPt: 0,
                absorbCondition: .any,
                splitMode: .none
            )
        )
    }

    // MARK: - Tests

    func testDiagnoseReportsMatchingRow() {
        // Tab bar elements in the bottom 12% of screen (y > 890 * 0.88 = 783.2)
        let elements = [
            point("Résumé", x: 100, y: 845),
            point("Partage", x: 300, y: 846),
        ]

        let report = ComponentTester.diagnose(
            definition: tabBarDefinition,
            elements: elements,
            screenHeight: screenHeight,
            allDefinitions: [tabBarDefinition]
        )

        XCTAssertTrue(report.contains("✅"), "Report should contain success marker for matching row")
        XCTAssertTrue(report.contains("tab-bar-item"), "Report should mention the component name")
        XCTAssertTrue(report.contains("matched"), "Report should state the match")
        XCTAssertTrue(report.contains("YOUR COMPONENT"), "Report should flag the tested component")
        XCTAssertTrue(report.contains("Row 0"), "Report should reference the matched row index")
    }

    func testDiagnoseReportsNoMatch() {
        // Content zone elements — tab bar definition requires tab_bar zone
        let elements = [
            point("General", x: 100, y: 400),
            point(">", x: 370, y: 400),
        ]

        let report = ComponentTester.diagnose(
            definition: tabBarDefinition,
            elements: elements,
            screenHeight: screenHeight,
            allDefinitions: [tabBarDefinition]
        )

        XCTAssertTrue(report.contains("❌"), "Report should contain failure marker when no rows match")
        XCTAssertTrue(report.contains("matched 0 rows"), "Report should state zero matches")
        XCTAssertTrue(report.contains("zone"), "Report should explain zone mismatch")
        XCTAssertTrue(
            report.contains("need tab_bar") || report.contains("need tab_bar, got content"),
            "Report should explain the zone mismatch specifically"
        )
    }

    func testDiagnoseShowsCompetingDefinition() {
        // Content zone row with chevron — matches disclosure, not tab-bar
        let elements = [
            point("General", x: 100, y: 400),
            point(">", x: 370, y: 400),
        ]

        let allDefs = [tabBarDefinition, disclosureDefinition]

        let report = ComponentTester.diagnose(
            definition: tabBarDefinition,
            elements: elements,
            screenHeight: screenHeight,
            allDefinitions: allDefs
        )

        // The disclosure definition should match the row, not our tab-bar definition
        XCTAssertTrue(
            report.contains("table-row-disclosure"),
            "Report should show the competing definition that actually matched"
        )
        XCTAssertTrue(report.contains("❌"), "Tab-bar definition should not match content zone rows")
    }

    func testDiagnoseHandlesEmptyScreen() {
        let report = ComponentTester.diagnose(
            definition: tabBarDefinition,
            elements: [],
            screenHeight: screenHeight,
            allDefinitions: [tabBarDefinition]
        )

        XCTAssertTrue(report.contains("0 OCR elements"), "Report should mention zero elements")
        XCTAssertTrue(
            report.contains("empty") || report.contains("No OCR elements"),
            "Report should indicate the screen is empty"
        )
        XCTAssertTrue(report.contains("No matches"), "Report should state no matches on empty screen")
    }

    func testDiagnoseFormatsRowProperties() {
        // Create a row with specific properties to verify formatting
        let elements = [
            point("Settings", x: 200, y: 50),     // nav bar zone (top 12%)
            point("Back", x: 50, y: 50),
        ]

        let report = ComponentTester.diagnose(
            definition: tabBarDefinition,
            elements: elements,
            screenHeight: screenHeight,
            allDefinitions: [tabBarDefinition]
        )

        // Verify row property formatting
        XCTAssertTrue(report.contains("zone=nav_bar"), "Report should show zone as nav_bar for top elements")
        XCTAssertTrue(report.contains("elements=2"), "Report should show element count")
        XCTAssertTrue(report.contains("chevron=false"), "Report should show chevron status")
        XCTAssertTrue(report.contains("height="), "Report should show row height")
    }

    // MARK: - Mismatch Explanation

    func testExplainMismatchReportsZone() {
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
            elementTexts: ["General", ">"]
        )

        let reasons = ComponentTester.explainMismatch(
            definition: tabBarDefinition, rowProps: rowProps
        )

        XCTAssertTrue(reasons.contains { $0.contains("zone") },
            "Should explain zone mismatch")
        XCTAssertTrue(reasons.contains { $0.contains("tab_bar") },
            "Should mention the required zone")
    }

    func testExplainMismatchReportsElementCount() {
        // Definition requires min 1, max 6 elements — test with 8
        let rowProps = ComponentDetector.RowProperties(
            elementCount: 8,
            hasChevron: false,
            hasNumericValue: false,
            rowHeight: 5,
            topY: 845,
            bottomY: 850,
            zone: .tabBar,
            hasStateIndicator: false,
            hasLongText: false,
            hasDismissButton: false,
            averageConfidence: 0.95,
            numericOnlyCount: 0,
            elementTexts: ["A", "B", "C", "D", "E", "F", "G", "H"]
        )

        let reasons = ComponentTester.explainMismatch(
            definition: tabBarDefinition, rowProps: rowProps
        )

        XCTAssertTrue(reasons.contains { $0.contains("too many elements") },
            "Should explain element count exceeds maximum")
    }

    // MARK: - Format Match Rules

    func testFormatMatchRulesIncludesAllFields() {
        let formatted = ComponentTester.formatMatchRules(tabBarDefinition.matchRules)

        XCTAssertTrue(formatted.contains("min_elements=1"), "Should include min_elements")
        XCTAssertTrue(formatted.contains("max_elements=6"), "Should include max_elements")
        XCTAssertTrue(formatted.contains("max_row_height_pt=60"), "Should include max_row_height_pt")
        XCTAssertTrue(formatted.contains("row_has_chevron=nil"), "Should show nil for optional fields")
    }

    // MARK: - Average Confidence Diagnostic

    func testDiagnoseShowsAverageConfidence() {
        let elements = [
            point("Résumé", x: 100, y: 845),
            point("Partage", x: 300, y: 846),
        ]

        let report = ComponentTester.diagnose(
            definition: tabBarDefinition,
            elements: elements,
            screenHeight: screenHeight,
            allDefinitions: [tabBarDefinition]
        )

        XCTAssertTrue(report.contains("avg_conf="),
            "Report should show average confidence per row")
    }

    func testExplainMismatchReportsConfidence() {
        let confDefinition = ComponentDefinition(
            name: "high-conf",
            platform: "ios",
            description: "Requires min confidence.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 6,
                maxRowHeightPt: 60, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .tabBar,
                minConfidence: 0.50, excludeNumericOnly: nil, textPattern: nil
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
            averageConfidence: 0.31, numericOnlyCount: 0,
            elementTexts: ["23", "Résumé"]
        )

        let reasons = ComponentTester.explainMismatch(
            definition: confDefinition, rowProps: rowProps
        )

        XCTAssertTrue(reasons.contains { $0.contains("confidence") },
            "Mismatch reasons should include confidence explanation")
        XCTAssertTrue(reasons.contains { $0.contains("0.50") },
            "Should show the required confidence threshold")
    }

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
