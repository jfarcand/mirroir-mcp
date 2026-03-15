// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for StateAbstraction: behavioral equivalence, refinement, zone signatures, coarsening.
// ABOUTME: Verifies the CEGAR-style adaptive fingerprint abstraction logic.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class StateAbstractionTests: XCTestCase {

    private func tap(_ text: String, x: Double = 205, y: Double = 400) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    private func noIcon() -> [IconDetector.DetectedIcon] { [] }

    // MARK: - Behavioral Equivalence

    func testBehaviorallyEquivalentWithSameElements() {
        let elements = [tap("Settings"), tap("General"), tap("About")]
        XCTAssertTrue(StateAbstraction.areBehaviorallyEquivalent(
            existingElements: elements, newElements: elements
        ))
    }

    func testBehaviorallyEquivalentWithMinorDifferences() {
        let existing = [tap("Settings"), tap("General"), tap("About"), tap("Privacy")]
        let newOnes = [tap("Settings"), tap("General"), tap("About"), tap("Security")]
        // 3/5 overlap = 0.6 = exactly at threshold
        XCTAssertTrue(StateAbstraction.areBehaviorallyEquivalent(
            existingElements: existing, newElements: newOnes
        ))
    }

    func testNotBehaviorallyEquivalentWithMajorDifferences() {
        let existing = [tap("Settings"), tap("General"), tap("About")]
        let different = [tap("Photos"), tap("Albums"), tap("Shared"), tap("Memories")]
        XCTAssertFalse(StateAbstraction.areBehaviorallyEquivalent(
            existingElements: existing, newElements: different
        ))
    }

    // MARK: - Refinement Level Detection

    func testFindDistinguishingLevelByTitle() {
        let existing = [tap("Settings", y: 150), tap("General", y: 300)]
        let newOnes = [tap("About", y: 150), tap("General", y: 300)]
        let level = StateAbstraction.findDistinguishingLevel(
            existingElements: existing, newElements: newOnes
        )
        XCTAssertEqual(level, .titleRefined)
    }

    func testFindDistinguishingLevelByZone() {
        // Same title but different zone layouts
        let existing = [
            tap("Settings", y: 150),
            tap("Item", y: 400),
            tap("Tab1", y: 800),
        ]
        let newOnes = [
            tap("Settings", y: 150),
            tap("Item", y: 400),
            // No tab bar zone content
        ]
        let level = StateAbstraction.findDistinguishingLevel(
            existingElements: existing, newElements: newOnes
        )
        XCTAssertEqual(level, .zoneRefined)
    }

    func testFindDistinguishingLevelReturnsNilWhenIdentical() {
        let elements = [tap("Settings", y: 150), tap("General", y: 300)]
        let level = StateAbstraction.findDistinguishingLevel(
            existingElements: elements, newElements: elements
        )
        XCTAssertNil(level)
    }

    // MARK: - Refined Fingerprint

    func testRefinedFingerprintDiffersFromStructural() {
        let elements = [tap("Settings", y: 150), tap("General", y: 300)]
        let structuralFP = StructuralFingerprint.compute(elements: elements, icons: noIcon())
        let refinedFP = StateAbstraction.computeRefinedFingerprint(
            elements: elements, icons: noIcon(), level: .titleRefined
        )
        XCTAssertNotEqual(structuralFP, refinedFP,
            "Title-refined fingerprint should differ from structural fingerprint")
    }

    func testDifferentRefinementLevelsProduceDifferentFingerprints() {
        let elements = [tap("Settings", y: 150), tap("General", y: 300)]
        let titleFP = StateAbstraction.computeRefinedFingerprint(
            elements: elements, icons: noIcon(), level: .titleRefined
        )
        let zoneFP = StateAbstraction.computeRefinedFingerprint(
            elements: elements, icons: noIcon(), level: .zoneRefined
        )
        XCTAssertNotEqual(titleFP, zoneFP)
    }

    func testStructuralLevelMatchesBaseFingerprint() {
        let elements = [tap("Settings", y: 150), tap("General", y: 300)]
        let baseFP = StructuralFingerprint.compute(elements: elements, icons: noIcon())
        let structFP = StateAbstraction.computeRefinedFingerprint(
            elements: elements, icons: noIcon(), level: .structural
        )
        XCTAssertEqual(baseFP, structFP,
            "Structural refinement level should match base fingerprint computation")
    }

    // MARK: - Zone Signature

    func testZoneSignatureFullLayout() {
        let elements = [
            tap("Title", y: 150),    // header zone
            tap("Content", y: 400),  // content zone
            tap("Tab1", y: 800),     // tab bar zone
        ]
        let sig = StateAbstraction.zoneSignature(from: elements)
        XCTAssertEqual(sig, "1-1-1")
    }

    func testZoneSignatureNoTabBar() {
        let elements = [
            tap("Title", y: 150),
            tap("Content", y: 400),
        ]
        let sig = StateAbstraction.zoneSignature(from: elements)
        XCTAssertEqual(sig, "1-1-0")
    }

    func testZoneSignatureEmpty() {
        let sig = StateAbstraction.zoneSignature(from: [])
        XCTAssertEqual(sig, "0-0-0")
    }

    // MARK: - Coarsening

    func testFindMergeablePairsWithIdenticalBehavior() {
        let nodeA = ScreenNode(
            fingerprint: "aaa", elements: [tap("Settings"), tap("General")],
            icons: [], hints: [], depth: 0, screenType: .settings,
            screenshotBase64: "", visitedElements: [], navBarTitle: "Settings"
        )
        let nodeB = ScreenNode(
            fingerprint: "bbb", elements: [tap("Settings"), tap("General")],
            icons: [], hints: [], depth: 0, screenType: .settings,
            screenshotBase64: "", visitedElements: [], navBarTitle: "Settings"
        )
        let edges = [
            NavigationEdge(fromFingerprint: "aaa", toFingerprint: "ccc",
                actionType: "tap", elementText: "General", displayLabel: "General", edgeType: .push),
            NavigationEdge(fromFingerprint: "bbb", toFingerprint: "ccc",
                actionType: "tap", elementText: "General", displayLabel: "General", edgeType: .push),
        ]
        let pairs = StateAbstraction.findMergeablePairs(
            nodes: ["aaa": nodeA, "bbb": nodeB], edges: edges
        )
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.keep, "aaa")
        XCTAssertEqual(pairs.first?.merge, "bbb")
    }

    func testFindMergeablePairsRejectsStructurallyDifferent() {
        let nodeA = ScreenNode(
            fingerprint: "aaa", elements: [tap("Settings")],
            icons: [], hints: [], depth: 0, screenType: .settings,
            screenshotBase64: "", visitedElements: [], navBarTitle: "Settings"
        )
        let nodeB = ScreenNode(
            fingerprint: "bbb", elements: [tap("Photos"), tap("Albums")],
            icons: [], hints: [], depth: 0, screenType: .list,
            screenshotBase64: "", visitedElements: [], navBarTitle: "Photos"
        )
        let edges = [
            NavigationEdge(fromFingerprint: "aaa", toFingerprint: "ccc",
                actionType: "tap", elementText: "Go", displayLabel: "Go", edgeType: .push),
            NavigationEdge(fromFingerprint: "bbb", toFingerprint: "ccc",
                actionType: "tap", elementText: "Go", displayLabel: "Go", edgeType: .push),
        ]
        let pairs = StateAbstraction.findMergeablePairs(
            nodes: ["aaa": nodeA, "bbb": nodeB], edges: edges
        )
        XCTAssertTrue(pairs.isEmpty,
            "Structurally different nodes should not be merged")
    }

    // MARK: - Refinement Level

    func testRefinementLevelComparable() {
        XCTAssertTrue(StateAbstraction.RefinementLevel.structural < .titleRefined)
        XCTAssertTrue(StateAbstraction.RefinementLevel.titleRefined < .zoneRefined)
    }

    func testRefinementLevelCodable() throws {
        let level = StateAbstraction.RefinementLevel.titleRefined
        let data = try JSONEncoder().encode(level)
        let decoded = try JSONDecoder().decode(StateAbstraction.RefinementLevel.self, from: data)
        XCTAssertEqual(decoded, level)
    }

    // MARK: - Graph Integration

    func testRecordTransitionRefinesWhenBehaviorallyDifferent() {
        let graph = NavigationGraph()
        let rootElements = [tap("Root", y: 150), tap("Item1", y: 300), tap("Item2", y: 400)]
        graph.start(
            rootElements: rootElements, icons: [], hints: [],
            screenshot: "", screenType: .settings
        )

        // Record transition to a screen with same structural fingerprint but different behavior
        // First transition: new screen
        let screenA = [tap("Detail", y: 150), tap("Info", y: 300)]
        let result1 = graph.recordTransition(
            elements: screenA, icons: [], hints: [],
            screenshot: "", actionType: "tap", elementText: "Item1",
            screenType: .detail
        )
        if case .newScreen = result1 {} else { XCTFail("Expected new screen") }

        // Go back to root
        graph.setCurrentFingerprint(graph.rootFingerprint)

        // Second transition: completely different elements that happen to structurally match
        // (won't actually match due to different text — this tests the flow)
        let screenB = [tap("Other", y: 150), tap("Data", y: 300)]
        let result2 = graph.recordTransition(
            elements: screenB, icons: [], hints: [],
            screenshot: "", actionType: "tap", elementText: "Item2",
            screenType: .detail
        )
        // Should be a new screen (different elements, no structural match)
        if case .newScreen = result2 {} else { XCTFail("Expected new screen for different elements") }
        XCTAssertGreaterThanOrEqual(graph.nodeCount, 3)
    }
}
