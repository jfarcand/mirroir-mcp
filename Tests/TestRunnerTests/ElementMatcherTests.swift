// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for ElementMatcher: exact, case-insensitive, and substring matching.
// ABOUTME: Covers match priorities, empty input, no-match scenarios, and visibility checks.

import XCTest
@testable import HelperLib
@testable import iphone_mirroir_mcp

final class ElementMatcherTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeTapPoint(text: String, x: Double = 100.0, y: Double = 200.0) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    // MARK: - Exact Match

    func testExactMatch() {
        let elements = [makeTapPoint(text: "General"), makeTapPoint(text: "About")]
        let result = ElementMatcher.findMatch(label: "General", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "General")
        XCTAssertEqual(result?.strategy, .exact)
    }

    func testExactMatchPreferredOverCaseInsensitive() {
        let elements = [makeTapPoint(text: "general"), makeTapPoint(text: "General")]
        let result = ElementMatcher.findMatch(label: "General", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "General")
        XCTAssertEqual(result?.strategy, .exact)
    }

    // MARK: - Case-Insensitive Match

    func testCaseInsensitiveMatch() {
        let elements = [makeTapPoint(text: "GENERAL"), makeTapPoint(text: "About")]
        let result = ElementMatcher.findMatch(label: "general", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "GENERAL")
        XCTAssertEqual(result?.strategy, .caseInsensitive)
    }

    // MARK: - Substring Match

    func testSubstringMatch() {
        let elements = [
            makeTapPoint(text: "General Settings"),
            makeTapPoint(text: "About")
        ]
        let result = ElementMatcher.findMatch(label: "General", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "General Settings")
        XCTAssertEqual(result?.strategy, .substring)
    }

    func testReverseSubstringMatch() {
        let elements = [makeTapPoint(text: "Gen"), makeTapPoint(text: "About")]
        let result = ElementMatcher.findMatch(label: "General", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "Gen")
        XCTAssertEqual(result?.strategy, .substring)
    }

    func testSubstringCaseInsensitive() {
        let elements = [makeTapPoint(text: "GENERAL SETTINGS")]
        let result = ElementMatcher.findMatch(label: "general", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.strategy, .substring)
    }

    // MARK: - No Match

    func testNoMatch() {
        let elements = [makeTapPoint(text: "General"), makeTapPoint(text: "About")]
        let result = ElementMatcher.findMatch(label: "Privacy", in: elements)
        XCTAssertNil(result)
    }

    func testEmptyLabel() {
        let elements = [makeTapPoint(text: "General")]
        let result = ElementMatcher.findMatch(label: "", in: elements)
        XCTAssertNil(result)
    }

    func testEmptyElements() {
        let result = ElementMatcher.findMatch(label: "General", in: [])
        XCTAssertNil(result)
    }

    func testBothEmpty() {
        let result = ElementMatcher.findMatch(label: "", in: [])
        XCTAssertNil(result)
    }

    // MARK: - isVisible

    func testIsVisibleTrue() {
        let elements = [makeTapPoint(text: "General")]
        XCTAssertTrue(ElementMatcher.isVisible(label: "General", in: elements))
    }

    func testIsVisibleFalse() {
        let elements = [makeTapPoint(text: "General")]
        XCTAssertFalse(ElementMatcher.isVisible(label: "Privacy", in: elements))
    }

    func testIsVisibleCaseInsensitive() {
        let elements = [makeTapPoint(text: "general")]
        XCTAssertTrue(ElementMatcher.isVisible(label: "General", in: elements))
    }

    // MARK: - Coordinate Preservation

    func testMatchPreservesCoordinates() {
        let elements = [makeTapPoint(text: "General", x: 150.0, y: 300.0)]
        let result = ElementMatcher.findMatch(label: "General", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.tapX, 150.0)
        XCTAssertEqual(result?.element.tapY, 300.0)
    }
}
