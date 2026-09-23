// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ScreenPlanner component-based plan building.
// ABOUTME: Verifies component plans and the safe Y boundary exclusion.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

extension ScreenPlannerTests {

    // MARK: - Component-Based Plan Building

    func testBuildComponentPlanFiltersNonClickable() {
        let elements = [
            TapPoint(text: "General", tapX: 100, tapY: 400, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 400, confidence: 0.9),
            TapPoint(text: "This is explanatory text for the section above that describes the setting",
                     tapX: 200, tapY: 500, confidence: 0.9),
        ]

        let classified = ElementClassifier.classify(elements, screenHeight: screenHeight)
        let components = ComponentDetector.detect(
            classified: classified,
            definitions: ComponentCatalog.definitions,
            screenHeight: screenHeight
        )
        let plan = ScreenPlanner.buildComponentPlan(
            components: components,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        let planTexts = Set(plan.map(\.point.text))
        XCTAssertTrue(planTexts.contains("General"),
            "Clickable disclosure row should appear in component plan")
        XCTAssertFalse(
            planTexts.contains("This is explanatory text for the section above that describes the setting"),
            "Non-clickable explanation text should be excluded from plan"
        )
    }

    func testBuildComponentPlanExcludesVisited() {
        let elements = [
            TapPoint(text: "General", tapX: 100, tapY: 300, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 300, confidence: 0.9),
            TapPoint(text: "Privacy", tapX: 100, tapY: 400, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 400, confidence: 0.9),
        ]

        let classified = ElementClassifier.classify(elements, screenHeight: screenHeight)
        let components = ComponentDetector.detect(
            classified: classified,
            definitions: ComponentCatalog.definitions,
            screenHeight: screenHeight
        )
        let plan = ScreenPlanner.buildComponentPlan(
            components: components,
            visitedElements: ["General"],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        let planTexts = plan.map(\.point.text)
        XCTAssertFalse(planTexts.contains("General"),
            "Visited elements should be excluded")
        XCTAssertTrue(planTexts.contains("Privacy"),
            "Non-visited elements should be included")
    }

    func testVisitedUsesDisplayLabelNotRawText() {
        // Two summary-card-like components whose tap targets are both "icon"
        // (YOLO detection), but displayLabels differ ("Activité" vs "Pas").
        // Visiting "Activité" should NOT mark "Pas" as visited.
        let summaryDef = ComponentDefinition(
            name: "summary-card", platform: "ios",
            description: "Summary card with icon tap target.",
            visualPattern: ["Icon + label text"],
            matchRules: ComponentMatchRules(
                rowHasChevron: false, chevronMode: nil,
                minElements: 1, maxElements: 6,
                maxRowHeightPt: 90, hasNumericValue: nil,
                hasLongText: nil, hasDismissButton: nil,
                zone: .content, minConfidence: nil,
                excludeNumericOnly: nil, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true, clickTarget: .firstNavigation,
                clickResult: .pushesScreen, backAfterClick: true,
                labelRule: .longestText
            ),
            exploration: ComponentExploration(
                explorable: true, role: .depthNavigation, priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: false, absorbsBelowWithinPt: 0,
                absorbCondition: .any, splitMode: .none
            )
        )

        let comp1 = ScreenComponent(
            kind: "summary-card", definition: summaryDef,
            elements: [
                ClassifiedElement(point: TapPoint(text: "icon", tapX: 200, tapY: 300, confidence: 0.9),
                                  role: .navigation, hasChevronContext: true),
                ClassifiedElement(point: TapPoint(text: "O Activité", tapX: 80, tapY: 300, confidence: 0.9),
                                  role: .navigation, hasChevronContext: true),
            ],
            tapTarget: TapPoint(text: "icon", tapX: 200, tapY: 300, confidence: 0.9),
            hasChevron: true, topY: 300, bottomY: 300
        )
        let comp2 = ScreenComponent(
            kind: "summary-card", definition: summaryDef,
            elements: [
                ClassifiedElement(point: TapPoint(text: "icon", tapX: 200, tapY: 500, confidence: 0.9),
                                  role: .navigation, hasChevronContext: true),
                ClassifiedElement(point: TapPoint(text: "O Pas", tapX: 80, tapY: 500, confidence: 0.9),
                                  role: .navigation, hasChevronContext: true),
            ],
            tapTarget: TapPoint(text: "icon", tapX: 200, tapY: 500, confidence: 0.9),
            hasChevron: true, topY: 500, bottomY: 500
        )

        // Visit "O Activité" (the displayLabel, not the raw "icon" text)
        let plan = ScreenPlanner.buildComponentPlan(
            components: [comp1, comp2],
            visitedElements: ["O Activité"],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        XCTAssertEqual(plan.count, 1,
            "Only one component should remain after visiting O Activité")
        XCTAssertEqual(plan[0].displayLabel, "O Pas",
            "O Pas should not be excluded when O Activité was visited")
    }

    func testBuildComponentPlanSortedByDescendingScore() {
        let elements = [
            TapPoint(text: "Low", tapX: 100, tapY: 100, confidence: 0.9),
            TapPoint(text: "High", tapX: 100, tapY: 450, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 450, confidence: 0.9),
        ]

        let classified = ElementClassifier.classify(elements, screenHeight: screenHeight)
        let components = ComponentDetector.detect(
            classified: classified,
            definitions: ComponentCatalog.definitions,
            screenHeight: screenHeight
        )
        let plan = ScreenPlanner.buildComponentPlan(
            components: components,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        for i in 0..<(plan.count - 1) {
            XCTAssertGreaterThanOrEqual(plan[i].score, plan[i + 1].score,
                "Component plan should be sorted by descending score")
        }
    }

    // MARK: - Safe Y Boundary

    func testElementsBelowSafeYExcludedFromPlan() {
        // screenHeight=890, safeBottomMarginPt=62 → safe Y threshold = 828
        let classified = [
            navElement("Safe Item", y: 700, hasChevron: true),
            navElement("Unsafe Item", y: 840, hasChevron: true),
        ]

        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        let planTexts = plan.map(\.point.text)
        XCTAssertTrue(planTexts.contains("Safe Item"),
            "Element above safe Y should be in plan")
        XCTAssertFalse(planTexts.contains("Unsafe Item"),
            "Element below safe Y threshold should be excluded from plan")
    }

    func testElementsAboveSafeYIncluded() {
        // Element just below the threshold (y=827 < 890-62=828)
        let classified = [
            navElement("Just Safe", y: 827, hasChevron: true),
        ]

        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].point.text, "Just Safe",
            "Element just above safe Y threshold should be included")
    }

    func testElementsBelowSafeYExcludedFromComponentPlan() {
        let elements = [
            TapPoint(text: "Safe Row", tapX: 100, tapY: 400, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 400, confidence: 0.9),
            TapPoint(text: "Unsafe Row", tapX: 100, tapY: 840, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 840, confidence: 0.9),
        ]

        let classified = ElementClassifier.classify(elements, screenHeight: screenHeight)
        let components = ComponentDetector.detect(
            classified: classified,
            definitions: ComponentCatalog.definitions,
            screenHeight: screenHeight
        )
        let plan = ScreenPlanner.buildComponentPlan(
            components: components,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        let planTexts = plan.map(\.point.text)
        XCTAssertTrue(planTexts.contains("Safe Row"),
            "Component above safe Y should be in plan")
        XCTAssertFalse(planTexts.contains("Unsafe Row"),
            "Component below safe Y threshold should be excluded from plan")
    }
}
