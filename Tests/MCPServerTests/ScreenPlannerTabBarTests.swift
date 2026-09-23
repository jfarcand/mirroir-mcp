// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ScreenPlanner tab bar exclusion and displayLabel wiring.
// ABOUTME: Verifies the Q-value boost keeps the breadth-front invariant.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

extension ScreenPlannerTests {

    // MARK: - Tab Bar Exclusion

    func testTabBarElementsExcludedFromComponentPlan() {
        let elements = [
            TapPoint(text: "General", tapX: 100, tapY: 400, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 400, confidence: 0.9),
            // Tab bar items in bottom 12% of 890pt screen (y > 783)
            TapPoint(text: "Resume", tapX: 100, tapY: 845, confidence: 0.9),
            TapPoint(text: "Partage", tapX: 300, tapY: 846, confidence: 0.9),
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
            "Content area element should be in plan")
        XCTAssertFalse(planTexts.contains("Resume"),
            "Tab bar item should not be in plan")
        XCTAssertFalse(planTexts.contains("Partage"),
            "Tab bar item should not be in plan")
    }

    func testBreadthNavigationExemptFromSafeYFilter() {
        // Tab bar items sit at the very bottom of the screen (y > screenHeight - 62pt).
        // breadth_navigation role should be exempt from the safe Y filter.
        let tabDef = ComponentDefinition(
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
                absorbsSameRow: false, absorbsBelowWithinPt: 0,
                absorbCondition: .any, splitMode: .none
            )
        )

        // Tab item at y=855 — below safe margin (890 - 62 = 828)
        let component = ScreenComponent(
            kind: "tab-bar-item",
            definition: tabDef,
            elements: [
                ClassifiedElement(
                    point: TapPoint(text: "Résumé", tapX: 100, tapY: 855, confidence: 0.9),
                    role: .navigation, hasChevronContext: false
                ),
            ],
            tapTarget: TapPoint(text: "Résumé", tapX: 100, tapY: 855, confidence: 0.9),
            hasChevron: false, topY: 855, bottomY: 855
        )

        let plan = ScreenPlanner.buildComponentPlan(
            components: [component],
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        XCTAssertEqual(plan.count, 1,
            "breadth_navigation should be exempt from safe Y filter")
        XCTAssertEqual(plan[0].point.text, "Résumé")
        XCTAssertTrue(plan[0].isBreadthNavigation,
            "breadth_navigation should be flagged on RankedElement")
    }

    func testNonBreadthComponentNotFlaggedAsBreadth() {
        // A normal navigational component should NOT have isBreadthNavigation set.
        let disclosureDef = ComponentDefinition(
            name: "table-row-disclosure",
            platform: "ios",
            description: "Settings row with chevron.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: .required, minElements: 1, maxElements: 6,
                maxRowHeightPt: 60, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .content,
                minConfidence: nil, excludeNumericOnly: nil, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true, clickTarget: .firstText,
                clickResult: .pushesScreen, backAfterClick: true,
                labelRule: .firstText
            ),
            exploration: ComponentExploration(
                explorable: true,
                role: .depthNavigation,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: false, absorbsBelowWithinPt: 0,
                absorbCondition: .any, splitMode: .none
            )
        )

        let component = ScreenComponent(
            kind: "table-row-disclosure",
            definition: disclosureDef,
            elements: [
                ClassifiedElement(
                    point: TapPoint(text: "General", tapX: 100, tapY: 400, confidence: 0.9),
                    role: .navigation, hasChevronContext: true
                ),
            ],
            tapTarget: TapPoint(text: "General", tapX: 100, tapY: 400, confidence: 0.9),
            hasChevron: true, topY: 400, bottomY: 400
        )

        let plan = ScreenPlanner.buildComponentPlan(
            components: [component],
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        XCTAssertEqual(plan.count, 1)
        XCTAssertFalse(plan[0].isBreadthNavigation,
            "Non-breadth component should not have isBreadthNavigation set")
    }

    func testBuildComponentPlanRespectsScoutResults() {
        let elements = [
            TapPoint(text: "Works", tapX: 100, tapY: 300, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 300, confidence: 0.9),
            TapPoint(text: "Broken", tapX: 100, tapY: 400, confidence: 0.9),
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
            visitedElements: [],
            scoutResults: ["Broken": .noChange, "Works": .navigated],
            screenHeight: screenHeight
        )

        XCTAssertEqual(plan[0].point.text, "Works",
            "Scout-confirmed navigation should rank first")
    }

    func testNonExplorableComponentsExcludedFromPlan() {
        // Toggle row is clickable (UI truth) but NOT explorable (exploration policy)
        let elements = [
            TapPoint(text: "Général", tapX: 100, tapY: 300, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 300, confidence: 0.9),
        ]
        let classified = ElementClassifier.classify(elements, screenHeight: screenHeight)
        let components = ComponentDetector.detect(
            classified: classified,
            definitions: ComponentCatalog.definitions,
            screenHeight: screenHeight
        )

        // Verify that all components in the plan are explorable
        let plan = ScreenPlanner.buildComponentPlan(
            components: components,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        // Every element in the plan should come from an explorable component
        for entry in plan {
            let source = components.first { $0.tapTarget?.text == entry.point.text }
            XCTAssertTrue(source?.definition.exploration.explorable ?? false,
                "Plan entry '\(entry.point.text)' should come from an explorable component")
        }
    }

    // MARK: - displayLabel Wiring

    func testComponentPlanCarriesDisplayLabel() {
        // Build a component with first_text label rule whose tapTarget differs from displayLabel
        let definition = ComponentDefinition(
            name: "tab-bar-item",
            platform: "ios",
            description: "Tab with icon and text",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil,
                minElements: 1, maxElements: 3,
                maxRowHeightPt: 60,
                hasNumericValue: nil, hasLongText: nil, hasDismissButton: nil,
                zone: .tabBar, minConfidence: 0.5,
                excludeNumericOnly: false, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true, clickTarget: .centered,
                clickResult: .switchesContext, backAfterClick: false,
                labelRule: .firstText
            ),
            exploration: ComponentExploration(
                explorable: true, role: .breadthNavigation, priority: .high
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true, absorbsBelowWithinPt: 0,
                absorbCondition: .any, splitMode: .perItem
            )
        )

        // The tap target is "icon" but the first non-decoration text is "Home"
        // Use Y=400 to avoid safe bottom margin exclusion (safeBottomMarginPt=62)
        let component = ScreenComponent(
            kind: "tab-bar-item",
            definition: definition,
            elements: [
                ClassifiedElement(
                    point: TapPoint(text: "icon", tapX: 50, tapY: 400, confidence: 0.8),
                    role: .navigation, hasChevronContext: false
                ),
                ClassifiedElement(
                    point: TapPoint(text: "Home", tapX: 50, tapY: 410, confidence: 0.9),
                    role: .navigation, hasChevronContext: false
                ),
            ],
            tapTarget: TapPoint(text: "icon", tapX: 50, tapY: 400, confidence: 0.8),
            hasChevron: false,
            topY: 400,
            bottomY: 410
        )

        let plan = ScreenPlanner.buildComponentPlan(
            components: [component],
            visitedElements: [],
            scoutResults: [:],
            screenHeight: 890
        )

        XCTAssertEqual(plan.count, 1)
        // Raw tap target is "icon" but displayLabel should be "Home" (firstText rule)
        XCTAssertEqual(plan[0].point.text, "icon", "Tap target should be raw OCR text")
        XCTAssertEqual(plan[0].displayLabel, "Home",
            "displayLabel should use firstText label rule, not raw tap target")
    }

    // MARK: - Q-Value Boost Breadth-Front Invariant

    func testApplyQBoostKeepsBreadthItemsInFront() {
        let tab = RankedElement(
            point: point("", x: 205, y: 846), score: 6.0,
            reason: "tab-synth(Reels@2,horizontal)",
            displayLabel: "Reels", isBreadthNavigation: true)
        let feedItem = RankedElement(
            point: point("Suggested post", y: 300), score: 6.5,
            reason: "nav", displayLabel: "Suggested post")

        let boosted = ScreenPlanner.applyQBoost(
            plan: [tab, feedItem], qValues: ["Suggested post": 1.0])

        // q=1.0 boosts the feed item to 8.5, above the tab's 6.0 — the breadth
        // tab must still lead the plan, un-boosted.
        XCTAssertEqual(boosted.count, 2)
        XCTAssertEqual(boosted[0].displayLabel, "Reels")
        XCTAssertEqual(boosted[0].score, 6.0,
            "Breadth items must not receive a Q-boost")
        XCTAssertEqual(boosted[1].displayLabel, "Suggested post")
        XCTAssertGreaterThanOrEqual(boosted[1].score, 8.0,
            "Non-breadth item should carry the Q-boosted score")
    }

    func testApplyQBoostPreservesDeclaredTabOrder() {
        let declaredOrder = ["Accueil", "Recherche", "Reels"]
        let tabs = declaredOrder.enumerated().map { index, name in
            RankedElement(
                point: point("", x: Double(41 + index * 82), y: 846), score: 6.0,
                reason: "tab-synth(\(name)@\(index),horizontal)",
                displayLabel: name, isBreadthNavigation: true)
        }
        // Q-values increasing in reverse declared order — a score re-sort would
        // flip the tabs to Reels, Recherche, Accueil.
        let qValues = ["Accueil": 0.0, "Recherche": 2.0, "Reels": 5.0]

        let boosted = ScreenPlanner.applyQBoost(plan: tabs, qValues: qValues)

        XCTAssertEqual(boosted.map { $0.displayLabel }, declaredOrder,
            "Breadth tabs must keep their declared relative order")
    }
}
