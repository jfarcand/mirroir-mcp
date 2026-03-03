// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for InputSimulation pure-logic methods: validateBounds and buildTypeSegments.
// ABOUTME: These methods are testable without system APIs since they only process coordinates and strings.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

final class InputSimulationLogicTests: XCTestCase {

    // We need a real InputSimulation instance to test its methods.
    // The bridge is not used by validateBounds or buildTypeSegments.
    private var simulation: InputSimulation!

    override func setUp() {
        super.setUp()
        let bridge = MirroringBridge()
        // Pass empty substitution to test pure segment logic independent of host keyboard layout
        simulation = InputSimulation(bridge: bridge, layoutSubstitution: [:])
    }

    // MARK: - validateBounds

    func testValidateBoundsInBounds() {
        let info = WindowInfo(
            windowID: 1, position: .zero,
            size: CGSize(width: 410, height: 898), pid: 1
        )
        let result = simulation.validateBounds(x: 200, y: 400, info: info, tag: "test")
        XCTAssertNil(result, "In-bounds coordinates should return nil")
    }

    func testValidateBoundsNegativeX() {
        let info = WindowInfo(
            windowID: 1, position: .zero,
            size: CGSize(width: 410, height: 898), pid: 1
        )
        let result = simulation.validateBounds(x: -1, y: 400, info: info, tag: "test")
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("outside") ?? false)
    }

    func testValidateBoundsXExceedsWidth() {
        let info = WindowInfo(
            windowID: 1, position: .zero,
            size: CGSize(width: 410, height: 898), pid: 1
        )
        let result = simulation.validateBounds(x: 420, y: 400, info: info, tag: "test")
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("outside") ?? false)
    }

    func testValidateBoundsYExceedsHeight() {
        let info = WindowInfo(
            windowID: 1, position: .zero,
            size: CGSize(width: 410, height: 898), pid: 1
        )
        let result = simulation.validateBounds(x: 200, y: 900, info: info, tag: "test")
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("outside") ?? false)
    }

    func testValidateBoundsAtEdge() {
        let info = WindowInfo(
            windowID: 1, position: .zero,
            size: CGSize(width: 410, height: 898), pid: 1
        )
        // Exactly at bounds should be valid
        let result = simulation.validateBounds(x: 410, y: 898, info: info, tag: "test")
        XCTAssertNil(result, "Coordinates at exactly the boundary should be valid")
    }

    // MARK: - buildTypeSegments

    func testBuildTypeSegmentsAllHID() {
        let segments = simulation.buildTypeSegments("hello")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.method, .keyEvent)
        XCTAssertEqual(segments.first?.text, "hello")
    }

    func testBuildTypeSegmentsEmptyString() {
        let segments = simulation.buildTypeSegments("")
        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: - buildTypeSegments with Accented Characters

    func testBuildTypeSegmentsCafeAllHID() {
        // "café" — all characters (c, a, f, é) have key mappings now
        let segments = simulation.buildTypeSegments("café")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.method, .keyEvent)
        XCTAssertEqual(segments.first?.text, "café")
    }

    func testBuildTypeSegmentsResumeAllHID() {
        // "résumé" — all characters have key mappings via dead-key sequences
        let segments = simulation.buildTypeSegments("résumé")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.method, .keyEvent)
        XCTAssertEqual(segments.first?.text, "résumé")
    }

    func testBuildTypeSegmentsMixedHIDAndPaste() {
        // "résumé 😀" — accented chars are HID, emoji is paste
        let segments = simulation.buildTypeSegments("résumé 😀")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].method, .keyEvent)
        XCTAssertEqual(segments[0].text, "résumé ")
        XCTAssertEqual(segments[1].method, .skip)
        XCTAssertEqual(segments[1].text, "😀")
    }

    func testBuildTypeSegmentsNaiveAllHID() {
        // "naïve" — ï is in the umlaut dead-key family
        let segments = simulation.buildTypeSegments("naïve")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.method, .keyEvent)
        XCTAssertEqual(segments.first?.text, "naïve")
    }

    func testBuildTypeSegmentsCedilla() {
        // "garçon" — ç is a direct Option+c character
        let segments = simulation.buildTypeSegments("garçon")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.method, .keyEvent)
        XCTAssertEqual(segments.first?.text, "garçon")
    }
}
