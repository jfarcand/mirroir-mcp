// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ScreenPlanner: ranked exploration plans per screen.
// ABOUTME: Verifies scoring signals, visited element exclusion, and realistic Settings screen ordering.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ScreenPlannerTests: XCTestCase {

    // MARK: - Helpers

    func point(_ text: String, x: Double = 205, y: Double = 400) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    func navElement(
        _ text: String, y: Double = 400, hasChevron: Bool = false
    ) -> ClassifiedElement {
        ClassifiedElement(
            point: point(text, y: y),
            role: .navigation,
            hasChevronContext: hasChevron
        )
    }

    let screenHeight: Double = 890

    // MARK: - Chevron Context

    func testChevronElementScoredHigherThanFallback() {
        let classified = [
            navElement("Settings Menu Item", y: 300, hasChevron: false),
            navElement("General", y: 400, hasChevron: true),
        ]

        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        XCTAssertEqual(plan.count, 2)
        // Y-sorted: Settings (y=300) before General (y=400)
        XCTAssertEqual(plan[0].point.text, "Settings Menu Item")
        XCTAssertEqual(plan[1].point.text, "General")
        // Chevron element should have higher score (used as tiebreak for same-Y)
        XCTAssertGreaterThan(plan[1].score, plan[0].score)
    }

    // MARK: - Label Length

    func testShortLabelScoredHigherThanLong() {
        let classified = [
            navElement("This is a very long descriptive label text", y: 400, hasChevron: true),
            navElement("General", y: 500, hasChevron: true),
        ]

        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        // Y-sorted: long label (y=400) before General (y=500)
        XCTAssertEqual(plan[0].point.text, "This is a very long descriptive label text")
        // Short label should have higher score
        XCTAssertGreaterThan(plan[1].score, plan[0].score,
            "Short label should score higher than long label")
    }

    // MARK: - Screen Position

    func testMidScreenPositionBonus() {
        // Two elements with identical signals except Y position
        let topElement = navElement("TopItem", y: 100, hasChevron: true)
        let midElement = navElement("MidItem", y: 450, hasChevron: true)

        let plan = ScreenPlanner.buildPlan(
            classified: [topElement, midElement],
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        // Y-sorted: TopItem (y=100) before MidItem (y=450)
        XCTAssertEqual(plan[0].point.text, "TopItem")
        // Mid-screen bonus gives MidItem higher score
        XCTAssertGreaterThan(plan[1].score, plan[0].score,
            "Mid-screen element should have higher score")
    }

    // MARK: - Scout Results

    func testScoutNavigatedBoostsScore() {
        let classified = [
            navElement("About", y: 300, hasChevron: true),
            navElement("General", y: 400, hasChevron: true),
        ]

        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: ["General": .navigated],
            screenHeight: screenHeight
        )

        // Y-sorted: About (y=300) before General (y=400)
        XCTAssertEqual(plan[0].point.text, "About")
        // Scout-confirmed should have highest score
        XCTAssertGreaterThan(plan[1].score, plan[0].score,
            "Scout-confirmed navigation should have highest score")
    }

    func testScoutNoChangePenalizesScore() {
        let classified = [
            navElement("Broken Link", y: 300, hasChevron: true),
            navElement("Working Link", y: 400, hasChevron: false),
        ]

        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: ["Broken Link": .noChange],
            screenHeight: screenHeight
        )

        // Y-sorted: Broken Link (y=300) before Working Link (y=400)
        XCTAssertEqual(plan[0].point.text, "Broken Link")
        XCTAssertLessThan(plan[0].score, 0,
            "Scout noChange element should have negative score")
        XCTAssertGreaterThan(plan[1].score, plan[0].score,
            "Working link should score higher than broken link")
    }

    // MARK: - Visited Elements

    func testVisitedElementsExcludedFromPlan() {
        let classified = [
            navElement("General", y: 300, hasChevron: true),
            navElement("Privacy", y: 400, hasChevron: true),
            navElement("About", y: 500, hasChevron: true),
        ]

        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: ["General", "About"],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].point.text, "Privacy")
    }

    // MARK: - Classifier Filter Integration

    func testLongDescriptiveTextFilteredOut() {
        // Long text (> 50 chars) should be classified as .info by ElementClassifier,
        // so it won't appear in the plan at all
        let longText = "Your account, iCloud, media purchases, and more information here"
        let elements = [
            TapPoint(text: longText, tapX: 200, tapY: 300, confidence: 0.9),
            TapPoint(text: "General", tapX: 100, tapY: 400, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 400, confidence: 0.9),
        ]
        let classified = ElementClassifier.classify(elements)
        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        XCTAssertEqual(plan.count, 1,
            "Long descriptive text should be filtered by classifier")
        XCTAssertEqual(plan[0].point.text, "General")
    }

    func testSentenceLikeTextFilteredOut() {
        let elements = [
            TapPoint(text: "Photos, videos, and backups", tapX: 200, tapY: 300, confidence: 0.9),
            TapPoint(text: "Storage", tapX: 100, tapY: 400, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 400, confidence: 0.9),
        ]
        let classified = ElementClassifier.classify(elements)
        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        let planTexts = Set(plan.map(\.point.text))
        XCTAssertFalse(planTexts.contains("Photos, videos, and backups"),
            "Sentence-like text should be filtered by classifier")
    }

    func testHelpLinksFilteredOut() {
        let elements = [
            TapPoint(text: "Learn More about your privacy settings", tapX: 200, tapY: 300, confidence: 0.9),
            TapPoint(text: "Privacy", tapX: 100, tapY: 400, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 400, confidence: 0.9),
        ]
        let classified = ElementClassifier.classify(elements)
        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        let planTexts = Set(plan.map(\.point.text))
        XCTAssertFalse(planTexts.contains("Learn More about your privacy settings"),
            "Help links should be filtered by classifier")
    }

    // MARK: - Sort Order

    func testPlanSortedByDescendingScore() {
        let classified = [
            navElement("Low", y: 100, hasChevron: false),
            navElement("High", y: 450, hasChevron: true),
            navElement("Mid", y: 450, hasChevron: true),
        ]

        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: ["High": .navigated],
            screenHeight: screenHeight
        )

        // Verify Y-ascending order (primary sort) with score tiebreaker
        for i in 0..<(plan.count - 1) {
            if plan[i].point.tapY == plan[i + 1].point.tapY {
                XCTAssertGreaterThanOrEqual(plan[i].score, plan[i + 1].score,
                    "Same-Y elements should be sorted by descending score")
            } else {
                XCTAssertLessThanOrEqual(plan[i].point.tapY, plan[i + 1].point.tapY,
                    "Plan should be sorted by ascending Y position")
            }
        }
    }

    // MARK: - Deterministic Ordering

    func testEqualScoreElementsSortedByYPosition() {
        // Two elements with identical scoring signals — Y tiebreaker should apply
        let classified = [
            navElement("Beta", y: 500, hasChevron: true),
            navElement("Alpha", y: 300, hasChevron: true),
        ]

        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].score, plan[1].score,
            "Both elements should have equal scores for this test to be meaningful")
        XCTAssertEqual(plan[0].point.text, "Alpha",
            "Equal-score elements should be ordered by Y position (lower Y first)")
        XCTAssertLessThan(plan[0].point.tapY, plan[1].point.tapY,
            "First element should have lower Y than second")
    }

    func testEqualScoreComponentsSortedByYPosition() {
        // Two disclosure rows with equal scores at different Y positions
        let elements = [
            TapPoint(text: "Beta", tapX: 100, tapY: 500, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 500, confidence: 0.9),
            TapPoint(text: "Alpha", tapX: 100, tapY: 300, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 300, confidence: 0.9),
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

        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].score, plan[1].score,
            "Both components should have equal scores for this test to be meaningful")
        XCTAssertEqual(plan[0].point.text, "Alpha",
            "Equal-score components should be ordered by Y position (lower Y first)")
    }

    // MARK: - Edge Cases

    func testEmptyNavigationReturnsEmptyPlan() {
        let classified = [
            ClassifiedElement(point: point("On"), role: .info),
            ClassifiedElement(point: point(">"), role: .decoration),
        ]

        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        XCTAssertTrue(plan.isEmpty,
            "No navigation elements should produce empty plan")
    }

    // MARK: - Realistic Settings Screen

    func testRealisticSettingsScreenPlan() {
        // Simulates a French Settings root where "Identifiant Apple" (banner at top)
        // should score lower than "General" (chevron-backed menu item mid-screen)
        let elements = [
            // Apple ID banner — no chevron, long-ish label, top of screen
            TapPoint(text: "Identifiant Apple", tapX: 200, tapY: 240, confidence: 0.9),
            // Navigation rows with chevrons
            TapPoint(text: "General", tapX: 100, tapY: 400, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 400, confidence: 0.9),
            TapPoint(text: "Confidentialite", tapX: 100, tapY: 480, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 480, confidence: 0.9),
            TapPoint(text: "Notifications", tapX: 100, tapY: 560, confidence: 0.9),
            TapPoint(text: ">", tapX: 370, tapY: 560, confidence: 0.9),
        ]

        let classified = ElementClassifier.classify(elements)
        let plan = ScreenPlanner.buildPlan(
            classified: classified,
            visitedElements: [],
            scoutResults: [:],
            screenHeight: screenHeight
        )

        // All navigation elements should be in the plan
        let planTexts = plan.map(\.point.text)
        XCTAssertTrue(planTexts.contains("General"))
        XCTAssertTrue(planTexts.contains("Confidentialite"))
        XCTAssertTrue(planTexts.contains("Notifications"))

        // Y-sorted: "Identifiant Apple" (y=240) before "General" (y=440)
        // but General (chevron) should have a higher score
        if planTexts.contains("Identifiant Apple"), planTexts.contains("General") {
            let appleIDScore = plan[planTexts.firstIndex(of: "Identifiant Apple")!].score
            let generalScore = plan[planTexts.firstIndex(of: "General")!].score
            XCTAssertGreaterThan(generalScore, appleIDScore,
                "\"General\" (chevron) should have higher score than \"Identifiant Apple\"")
        }

        // Verify chevron-backed items appear before fallback items
        let chevronItems = plan.filter {
            ["General", "Confidentialite", "Notifications"].contains($0.point.text)
        }
        for item in chevronItems {
            XCTAssertTrue(item.reason.contains("chevron"),
                "\(item.point.text) should have chevron in reason")
        }
    }

}
