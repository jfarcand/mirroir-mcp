// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for PlanCoordinateResolver: matching plan items to fresh viewport coordinates.
// ABOUTME: Verifies exact match, case-insensitive, containment, and needsScroll resolution.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class PlanCoordinateResolverTests: XCTestCase {

    private func makePlanItem(
        label: String, x: Double = 200, y: Double = 500, score: Double = 5.0
    ) -> RankedElement {
        let point = TapPoint(text: label, tapX: x, tapY: y, confidence: 0.9)
        return RankedElement(point: point, score: score, reason: "test", displayLabel: label)
    }

    private func makeViewport(_ items: [(String, Double, Double)]) -> [TapPoint] {
        items.map { TapPoint(text: $0.0, tapX: $0.1, tapY: $0.2, confidence: 0.9) }
    }

    // MARK: - Exact Match

    func testExactMatchReturnsFound() {
        let planItem = makePlanItem(label: "Activité", x: 200, y: 800)
        let viewport = makeViewport([
            ("Résumé", 100, 100),
            ("Activité", 205, 350),
            ("Distance", 200, 450),
        ])

        let result = PlanCoordinateResolver.resolve(planItem: planItem, viewportElements: viewport)

        guard case .found(let fresh) = result else {
            return XCTFail("Expected .found, got \(result)")
        }
        // Fresh coordinates from viewport, not stale plan coordinates
        XCTAssertEqual(fresh.tapX, 205, accuracy: 0.1)
        XCTAssertEqual(fresh.tapY, 350, accuracy: 0.1)
        XCTAssertEqual(fresh.text, "Activité")
    }

    // MARK: - Case-Insensitive Match

    func testCaseInsensitiveMatchReturnsFound() {
        let planItem = makePlanItem(label: "général")
        let viewport = makeViewport([("Général", 200, 300)])

        let result = PlanCoordinateResolver.resolve(planItem: planItem, viewportElements: viewport)

        guard case .found(let fresh) = result else {
            return XCTFail("Expected .found, got \(result)")
        }
        XCTAssertEqual(fresh.text, "Général")
    }

    // MARK: - Containment Match

    func testContainmentMatchWhenViewportHasLongerText() {
        let planItem = makePlanItem(label: "Version")
        let viewport = makeViewport([("Version 16.4.1", 200, 300)])

        let result = PlanCoordinateResolver.resolve(planItem: planItem, viewportElements: viewport)

        guard case .found(let fresh) = result else {
            return XCTFail("Expected .found, got \(result)")
        }
        XCTAssertEqual(fresh.text, "Version 16.4.1")
    }

    func testContainmentMatchWhenPlanLabelIsLonger() {
        let planItem = makePlanItem(label: "Fréquence cardiaque")
        let viewport = makeViewport([("Fréquence", 200, 300)])

        let result = PlanCoordinateResolver.resolve(planItem: planItem, viewportElements: viewport)

        guard case .found(let fresh) = result else {
            return XCTFail("Expected .found, got \(result)")
        }
        XCTAssertEqual(fresh.text, "Fréquence")
    }

    // MARK: - Not Found

    func testNoMatchReturnsNeedsScroll() {
        let planItem = makePlanItem(label: "Étages montés")
        let viewport = makeViewport([
            ("Résumé", 100, 100),
            ("Activité", 200, 300),
        ])

        let result = PlanCoordinateResolver.resolve(planItem: planItem, viewportElements: viewport)

        guard case .needsScroll = result else {
            return XCTFail("Expected .needsScroll, got \(result)")
        }
    }

    func testEmptyViewportReturnsNeedsScroll() {
        let planItem = makePlanItem(label: "Activité")
        let result = PlanCoordinateResolver.resolve(planItem: planItem, viewportElements: [])

        guard case .needsScroll = result else {
            return XCTFail("Expected .needsScroll, got \(result)")
        }
    }

    // MARK: - Short Labels Skip Containment

    func testShortLabelsDoNotUseContainmentMatch() {
        // Labels shorter than 3 chars should not use containment (too ambiguous)
        let planItem = makePlanItem(label: "Pa")
        let viewport = makeViewport([("Partage", 200, 300)])

        let result = PlanCoordinateResolver.resolve(planItem: planItem, viewportElements: viewport)

        guard case .needsScroll = result else {
            return XCTFail("Expected .needsScroll for short label, got \(result)")
        }
    }

    // MARK: - Fresh Coordinates

    func testWithFreshCoordinatesPreservesScoreAndLabel() {
        let planItem = makePlanItem(label: "Activité", x: 200, y: 800, score: 7.5)
        let freshPoint = TapPoint(text: "Activité", tapX: 205, tapY: 350, confidence: 0.95)

        let resolved = PlanCoordinateResolver.withFreshCoordinates(
            planItem: planItem, freshPoint: freshPoint
        )

        XCTAssertEqual(resolved.displayLabel, "Activité")
        XCTAssertEqual(resolved.score, 7.5)
        XCTAssertEqual(resolved.point.tapX, 205, accuracy: 0.1)
        XCTAssertEqual(resolved.point.tapY, 350, accuracy: 0.1)
        XCTAssertEqual(resolved.reason, "test")
    }

    // MARK: - Priority Order

    func testExactMatchTakesPriorityOverContainment() {
        let planItem = makePlanItem(label: "Distance")
        let viewport = makeViewport([
            ("Distance à vélo", 200, 300),
            ("Distance", 200, 400),
        ])

        let result = PlanCoordinateResolver.resolve(planItem: planItem, viewportElements: viewport)

        guard case .found(let fresh) = result else {
            return XCTFail("Expected .found, got \(result)")
        }
        // Should pick exact match at Y=400, not containment match at Y=300
        XCTAssertEqual(fresh.tapY, 400, accuracy: 0.1)
    }
}
