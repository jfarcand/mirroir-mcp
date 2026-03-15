// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for smart scrolling: exhaustion detection, infinite scroll flagging, graph state.
// ABOUTME: Tests Phase 6 scroll enhancements on NavigationGraph and CalibrationScroller.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class SmartScrollTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        texts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 205, tapY: startY + Double(i) * 80, confidence: 0.95)
        }
    }

    private func makeGraph() -> NavigationGraph {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings", "General", "Privacy"]),
            icons: [], hints: ["back_button"],
            screenshot: "base64img", screenType: .settings
        )
        return graph
    }

    // MARK: - Scroll State Tracking

    func testMarkInfiniteScroll() {
        let graph = makeGraph()
        let fp = graph.currentFingerprint

        XCTAssertFalse(graph.isInfiniteScroll(fingerprint: fp))
        graph.markInfiniteScroll(fingerprint: fp)
        XCTAssertTrue(graph.isInfiniteScroll(fingerprint: fp))
    }

    func testMarkScrollExhausted() {
        let graph = makeGraph()
        let fp = graph.currentFingerprint

        XCTAssertFalse(graph.isScrollExhausted(fingerprint: fp))
        graph.markScrollExhausted(fingerprint: fp)
        XCTAssertTrue(graph.isScrollExhausted(fingerprint: fp))
    }

    func testScrollStateDoesNotAffectUnknownFingerprint() {
        let graph = makeGraph()
        XCTAssertFalse(graph.isInfiniteScroll(fingerprint: "nonexistent"))
        XCTAssertFalse(graph.isScrollExhausted(fingerprint: "nonexistent"))
    }

    func testScrollStatePreservedInSnapshot() {
        let graph = makeGraph()
        let fp = graph.currentFingerprint

        graph.markInfiniteScroll(fingerprint: fp)
        graph.markScrollExhausted(fingerprint: fp)

        let snapshot = graph.finalize()
        let node = snapshot.nodes[fp]
        XCTAssertTrue(node?.isInfiniteScroll ?? false)
        XCTAssertTrue(node?.scrollExhausted ?? false)
    }

    func testScrollStatePersistenceRoundtrip() {
        let graph = makeGraph()
        let fp = graph.currentFingerprint
        let bundleID = "com.test.SmartScrollTests"

        graph.markInfiniteScroll(fingerprint: fp)
        graph.markScrollExhausted(fingerprint: fp)

        let snapshot = graph.finalize()
        GraphPersistence.save(snapshot: snapshot, bundleID: bundleID)

        defer { GraphPersistence.delete(bundleID: bundleID) }

        guard let loaded = GraphPersistence.load(bundleID: bundleID) else {
            return XCTFail("Should load persisted graph")
        }

        let node = loaded.nodes[fp]
        XCTAssertTrue(node?.isInfiniteScroll ?? false,
            "isInfiniteScroll should survive persistence roundtrip")
        XCTAssertTrue(node?.scrollExhausted ?? false,
            "scrollExhausted should survive persistence roundtrip")
    }

    // MARK: - ScreenNode Default Values

    func testScreenNodeDefaultsToNoInfiniteScroll() {
        let node = ScreenNode(
            fingerprint: "test", elements: [], icons: [], hints: [],
            depth: 0, screenType: .unknown, screenshotBase64: "",
            visitedElements: [], navBarTitle: nil
        )
        XCTAssertFalse(node.isInfiniteScroll)
        XCTAssertFalse(node.scrollExhausted)
    }

    // MARK: - Exhaustion Threshold

    func testExhaustionThresholdIsReasonable() {
        // Threshold should be between 0 and 1
        XCTAssertGreaterThan(CalibrationScroller.exhaustionThreshold, 0.0)
        XCTAssertLessThanOrEqual(CalibrationScroller.exhaustionThreshold, 0.5)
    }
}
