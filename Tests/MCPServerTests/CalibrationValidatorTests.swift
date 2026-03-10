// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for CalibrationValidator: quality gate for calibration pipeline.
// ABOUTME: Verifies unclassified ratio checking, zone filtering, and diagnostic report generation.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class CalibrationValidatorTests: XCTestCase {

    private let screenHeight: Double = 890

    private func makeClassified(_ text: String, y: Double) -> ClassifiedElement {
        let point = TapPoint(text: text, tapX: 200, tapY: y, confidence: 0.9)
        return ClassifiedElement(point: point, role: .navigation, hasChevronContext: false)
    }

    private func makeComponent(
        kind: String, label: String, topY: Double, explorable: Bool = true
    ) -> ScreenComponent {
        let element = makeClassified(label, y: topY)
        let matchRules = ComponentMatchRules(
            rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 4,
            maxRowHeightPt: 90, hasNumericValue: nil, hasLongText: nil,
            hasDismissButton: nil, zone: .content,
            minConfidence: nil, excludeNumericOnly: nil, textPattern: nil
        )
        let interaction = ComponentInteraction(
            clickable: true, clickTarget: .firstNavigation,
            clickResult: .pushesScreen, backAfterClick: true, labelRule: .tapTarget
        )
        let exploration = ComponentExploration(
            explorable: explorable, role: .depthNavigation, priority: .normal
        )
        let grouping = ComponentGrouping(
            absorbsSameRow: false, absorbsBelowWithinPt: 0,
            absorbCondition: .any, splitMode: .none
        )
        let def = ComponentDefinition(
            name: kind, platform: "ios", description: "",
            visualPattern: [], matchRules: matchRules,
            interaction: interaction, exploration: exploration, grouping: grouping
        )
        return ScreenComponent(
            kind: kind, definition: def, elements: [element],
            tapTarget: element.point, hasChevron: false,
            topY: topY, bottomY: topY
        )
    }

    // MARK: - Validation Logic

    func testAllClassifiedPassesValidation() {
        let components = [
            makeComponent(kind: "summary-card", label: "Activité", topY: 300),
            makeComponent(kind: "summary-card", label: "Distance", topY: 400),
            makeComponent(kind: "table-row-disclosure", label: "Général", topY: 500),
        ]

        let result = CalibrationValidator.validate(
            components: components, screenHeight: screenHeight,
            strict: true, threshold: 0.5
        )

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.unclassifiedCount, 0)
        XCTAssertEqual(result.unclassifiedRatio, 0.0, accuracy: 0.01)
        XCTAssertEqual(result.componentCounts["summary-card"], 2)
        XCTAssertEqual(result.componentCounts["table-row-disclosure"], 1)
    }

    func testAllUnclassifiedFailsInStrictMode() {
        let components = [
            makeComponent(kind: "unclassified", label: "Mystery1", topY: 300),
            makeComponent(kind: "unclassified", label: "Mystery2", topY: 400),
        ]

        let result = CalibrationValidator.validate(
            components: components, screenHeight: screenHeight,
            strict: true, threshold: 0.5
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.unclassifiedCount, 2)
        XCTAssertEqual(result.unclassifiedRatio, 1.0, accuracy: 0.01)
    }

    func testAllUnclassifiedPassesInNonStrictMode() {
        let components = [
            makeComponent(kind: "unclassified", label: "Mystery1", topY: 300),
            makeComponent(kind: "unclassified", label: "Mystery2", topY: 400),
        ]

        let result = CalibrationValidator.validate(
            components: components, screenHeight: screenHeight,
            strict: false, threshold: 0.5
        )

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.unclassifiedCount, 2)
    }

    func testNavBarAndTabBarExcludedFromRatio() {
        // Tab bar zone (bottom 12%): Y > 890 * 0.88 = 783
        let tabComponent = makeComponent(kind: "unclassified", label: "TabThing", topY: 850)
        // Nav bar zone (top 12%): Y < 890 * 0.12 = 107
        let navComponent = makeComponent(kind: "unclassified", label: "NavThing", topY: 50)
        // Content zone: classified
        let contentComponent = makeComponent(kind: "summary-card", label: "Card", topY: 400)

        let result = CalibrationValidator.validate(
            components: [tabComponent, navComponent, contentComponent],
            screenHeight: screenHeight, strict: true, threshold: 0.5
        )

        // Only 1 content element (summary-card), 0 unclassified in content → passes
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.totalContentElements, 1)
        XCTAssertEqual(result.unclassifiedCount, 0)
    }

    func testThresholdBoundary() {
        // 2 content components: 1 classified, 1 unclassified → ratio 0.5
        let components = [
            makeComponent(kind: "summary-card", label: "Card", topY: 300),
            makeComponent(kind: "unclassified", label: "Unknown", topY: 400),
        ]

        // At threshold (0.5) should pass
        let atThreshold = CalibrationValidator.validate(
            components: components, screenHeight: screenHeight,
            strict: true, threshold: 0.5
        )
        XCTAssertTrue(atThreshold.passed)

        // Below threshold (0.4) should fail
        let belowThreshold = CalibrationValidator.validate(
            components: components, screenHeight: screenHeight,
            strict: true, threshold: 0.4
        )
        XCTAssertFalse(belowThreshold.passed)
    }

    func testEmptyComponentsPassValidation() {
        let result = CalibrationValidator.validate(
            components: [], screenHeight: screenHeight,
            strict: true, threshold: 0.5
        )
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.totalContentElements, 0)
    }

    // MARK: - Report Generation

    func testReportContainsMatchedComponents() {
        let components = [
            makeComponent(kind: "summary-card", label: "Activité", topY: 300),
            makeComponent(kind: "tab-bar-item", label: "Résumé", topY: 850),
        ]

        let result = CalibrationValidator.validate(
            components: components, screenHeight: screenHeight
        )

        XCTAssertTrue(result.report.contains("summary-card"))
        XCTAssertTrue(result.report.contains("Activité"))
    }

    func testReportContainsUnclassifiedDetails() {
        let components = [
            makeComponent(kind: "unclassified", label: "Modifier", topY: 180),
        ]

        let result = CalibrationValidator.validate(
            components: components, screenHeight: screenHeight,
            strict: true, threshold: 0.0
        )

        XCTAssertTrue(result.report.contains("Unclassified"))
        XCTAssertTrue(result.report.contains("Modifier"))
        XCTAssertTrue(result.report.contains("content zone"))
    }
}
