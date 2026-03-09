// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ScreenComponent.displayLabel computed property.
// ABOUTME: Verifies label rules correctly filter OCR artifacts from human-readable labels.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class DisplayLabelTests: XCTestCase {

    // MARK: - Helpers

    private func element(
        _ text: String, role: ElementRole = .navigation, x: Double = 200, y: Double = 400
    ) -> ClassifiedElement {
        ClassifiedElement(
            point: TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95),
            role: role
        )
    }

    private func makeComponent(
        labelRule: LabelRule,
        elements: [ClassifiedElement],
        tapTarget: TapPoint? = nil
    ) -> ScreenComponent {
        let definition = ComponentDefinition(
            name: "test-component",
            platform: "ios",
            description: "Test component.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 10,
                maxRowHeightPt: 100, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .content,
                minConfidence: nil, excludeNumericOnly: nil, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true,
                clickTarget: .firstNavigation,
                clickResult: .pushesScreen,
                backAfterClick: true,
                labelRule: labelRule
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

        return ScreenComponent(
            kind: "test-component",
            definition: definition,
            elements: elements,
            tapTarget: tapTarget ?? elements.first?.point,
            hasChevron: false,
            topY: 400,
            bottomY: 400
        )
    }

    // MARK: - tapTarget Rule (Default)

    func testTapTargetRuleUsesTargetText() {
        let els = [
            element("icon", role: .decoration, x: 100),
            element("Résumé", x: 200)
        ]
        let component = makeComponent(
            labelRule: .tapTarget, elements: els,
            tapTarget: els[1].point
        )

        XCTAssertEqual(component.displayLabel, "Résumé")
    }

    func testTapTargetRuleFallsBackWhenNilTarget() {
        let els = [element("Résumé", x: 200)]
        let component = makeComponent(
            labelRule: .tapTarget, elements: els,
            tapTarget: nil
        )

        XCTAssertEqual(component.displayLabel, "Résumé",
            "Falls back to first non-decoration element text")
    }

    // MARK: - firstText Rule

    func testFirstTextSkipsDecorationAndIcon() {
        let els = [
            element("icon", role: .decoration, x: 100),
            element(">", role: .decoration, x: 300),
            element("Général", x: 200)
        ]
        let component = makeComponent(
            labelRule: .firstText, elements: els
        )

        XCTAssertEqual(component.displayLabel, "Général",
            "firstText should skip decoration and icon elements")
    }

    func testFirstTextSkipsChevronCharacters() {
        let els = [
            element(">", role: .navigation, x: 300),
            element("Activité", x: 200)
        ]
        let component = makeComponent(
            labelRule: .firstText, elements: els
        )

        XCTAssertEqual(component.displayLabel, "Activité",
            "firstText should skip chevron characters")
    }

    func testFirstTextFallsBackToKind() {
        let els = [
            element("icon", role: .decoration, x: 100),
            element(">", role: .decoration, x: 300)
        ]
        let component = makeComponent(
            labelRule: .firstText, elements: els
        )

        XCTAssertEqual(component.displayLabel, "test-component",
            "Falls back to component kind when no valid text found")
    }

    // MARK: - longestText Rule

    func testLongestTextPicksLongest() {
        let els = [
            element("AB", role: .navigation, x: 100),
            element("Activité physique", role: .info, x: 200),
            element(">", role: .decoration, x: 300)
        ]
        let component = makeComponent(
            labelRule: .longestText, elements: els
        )

        XCTAssertEqual(component.displayLabel, "Activité physique",
            "longestText should pick the longest non-decoration element")
    }

    func testLongestTextSkipsDecoration() {
        let els = [
            element("icon decoration placeholder text", role: .decoration, x: 100),
            element("Short", role: .navigation, x: 200)
        ]
        let component = makeComponent(
            labelRule: .longestText, elements: els
        )

        XCTAssertEqual(component.displayLabel, "Short",
            "longestText should skip decoration elements even if longer")
    }
}
