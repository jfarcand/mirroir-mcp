// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for GraphPersistence: save/load roundtrip, version checking, file management.
// ABOUTME: Uses temporary directories to avoid polluting the real graph storage.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class GraphPersistenceTests: XCTestCase {

    /// Test bundle ID used for all persistence tests.
    private let testBundleID = "com.test.GraphPersistenceTests"

    override func tearDown() {
        super.tearDown()
        // Clean up any test graphs
        GraphPersistence.delete(bundleID: testBundleID)
    }

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

    // MARK: - Save and Load Roundtrip

    func testSaveAndLoadRoundtrip() {
        let graph = makeGraph()
        let rootFP = graph.currentFingerprint

        // Add a second screen via transition
        let childElements = makeElements(["About", "Version", "Model"])
        _ = graph.recordTransition(
            elements: childElements, icons: [], hints: ["back_button"],
            screenshot: "child_img", actionType: "tap",
            elementText: "General", screenType: .detail
        )

        // Mark an element visited and an edge dead
        graph.markElementVisited(fingerprint: rootFP, elementText: "Privacy")
        graph.markEdgeDead(fromFingerprint: rootFP, elementText: "DeadElement")

        let snapshot = graph.finalize()

        // Save
        let savedURL = GraphPersistence.save(snapshot: snapshot, bundleID: testBundleID)
        XCTAssertNotNil(savedURL, "Save should return a URL")

        // Load
        guard let loaded = GraphPersistence.load(bundleID: testBundleID) else {
            return XCTFail("Load should return a snapshot")
        }

        // Verify structure preserved
        XCTAssertEqual(loaded.nodes.count, 2, "Should have 2 nodes")
        XCTAssertEqual(loaded.edges.count, 1, "Should have 1 edge")
        XCTAssertEqual(loaded.rootFingerprint, rootFP)
        XCTAssertEqual(loaded.deadEdges.count, 1)
        XCTAssertTrue(loaded.deadEdges.contains("\(rootFP):DeadElement"))

        // Verify node data
        let rootNode = loaded.nodes[rootFP]
        XCTAssertNotNil(rootNode)
        XCTAssertEqual(rootNode?.elements.count, 3)
        XCTAssertTrue(rootNode?.visitedElements.contains("Privacy") ?? false)
        XCTAssertEqual(rootNode?.screenType, .settings)
        XCTAssertEqual(rootNode?.hints, ["back_button"])

        // Verify edge data
        let edge = loaded.edges.first
        XCTAssertNotNil(edge)
        XCTAssertEqual(edge?.fromFingerprint, rootFP)
        XCTAssertEqual(edge?.elementText, "General")
        XCTAssertEqual(edge?.actionType, "tap")
    }

    func testElementCoordinatesPreserved() {
        let graph = makeGraph()
        let snapshot = graph.finalize()

        GraphPersistence.save(snapshot: snapshot, bundleID: testBundleID)
        guard let loaded = GraphPersistence.load(bundleID: testBundleID) else {
            return XCTFail("Should load")
        }

        let rootNode = loaded.nodes[loaded.rootFingerprint]
        XCTAssertNotNil(rootNode)
        guard let firstElement = rootNode?.elements.first else {
            return XCTFail("Should have at least one element")
        }
        XCTAssertEqual(firstElement.text, "Settings")
        XCTAssertEqual(firstElement.tapX, 205, accuracy: 0.01)
        XCTAssertEqual(firstElement.tapY, 120, accuracy: 0.01)
    }

    // MARK: - Edge Types

    func testEdgeTypesPreserved() {
        let graph = makeGraph()

        // Record a modal-type transition
        _ = graph.recordTransition(
            elements: makeElements(["Close", "Content"]),
            icons: [], hints: [],
            screenshot: "modal_img", actionType: "tap",
            elementText: "Info", screenType: .modal,
            edgeType: .modal
        )

        let snapshot = graph.finalize()
        GraphPersistence.save(snapshot: snapshot, bundleID: testBundleID)
        guard let loaded = GraphPersistence.load(bundleID: testBundleID) else {
            return XCTFail("Should load")
        }

        XCTAssertEqual(loaded.edges.first?.edgeType, .modal)
    }

    // MARK: - Missing File

    func testLoadReturnsNilForMissingFile() {
        let result = GraphPersistence.load(bundleID: "com.nonexistent.app")
        XCTAssertNil(result)
    }

    // MARK: - Exists Check

    func testExistsReturnsFalseForMissingGraph() {
        XCTAssertFalse(GraphPersistence.exists(bundleID: "com.nonexistent.app"))
    }

    func testExistsReturnsTrueAfterSave() {
        let graph = makeGraph()
        GraphPersistence.save(snapshot: graph.finalize(), bundleID: testBundleID)
        XCTAssertTrue(GraphPersistence.exists(bundleID: testBundleID))
    }

    // MARK: - Delete

    func testDeleteRemovesGraph() {
        let graph = makeGraph()
        GraphPersistence.save(snapshot: graph.finalize(), bundleID: testBundleID)
        XCTAssertTrue(GraphPersistence.exists(bundleID: testBundleID))

        let deleted = GraphPersistence.delete(bundleID: testBundleID)
        XCTAssertTrue(deleted)
        XCTAssertFalse(GraphPersistence.exists(bundleID: testBundleID))
    }

    func testDeleteReturnsFalseForMissingFile() {
        let deleted = GraphPersistence.delete(bundleID: "com.nonexistent.app")
        XCTAssertFalse(deleted)
    }

    // MARK: - Graph URL Sanitization

    func testGraphURLSanitizesBundleID() {
        let url = GraphPersistence.graphURL(for: "com.apple/test:special")
        XCTAssertTrue(url.lastPathComponent.contains("com.apple_test_special"))
        XCTAssertTrue(url.pathExtension == "json")
    }

    // MARK: - Corrupt File Handling

    func testLoadHandlesCorruptFile() throws {
        let fileURL = GraphPersistence.graphURL(for: testBundleID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not valid json".data(using: .utf8)!.write(to: fileURL)

        let result = GraphPersistence.load(bundleID: testBundleID)
        XCTAssertNil(result, "Corrupt file should return nil")
    }

    // MARK: - Screenshots Not Persisted

    func testScreenshotsNotPersisted() throws {
        let graph = makeGraph()
        GraphPersistence.save(snapshot: graph.finalize(), bundleID: testBundleID)

        // Read the raw JSON and verify no base64 screenshot data
        let fileURL = GraphPersistence.graphURL(for: testBundleID)
        let data = try Data(contentsOf: fileURL)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("base64img"),
            "Screenshot data should not be persisted")
    }
}
