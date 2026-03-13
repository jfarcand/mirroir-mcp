// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for VisionResponseParser — JSON extraction, coordinate scaling, and hint derivation.
// ABOUTME: Validates parsing of AI vision model responses into TapPoint arrays.

import XCTest
@testable import mirroir_mcp
@testable import HelperLib

final class VisionResponseParserTests: XCTestCase {

    // MARK: - JSON Extraction

    func testExtractJSONFromPlainArray() {
        let input = """
        [{"label": "Météo", "x": 100, "y": 150, "type": "app"}]
        """
        let result = VisionResponseParser.extractJSON(from: input)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.hasPrefix("["))
    }

    func testExtractJSONFromMarkdownFence() {
        let input = """
        Here are the elements:
        ```json
        [{"label": "Settings", "x": 200, "y": 300, "type": "app"}]
        ```
        That's all I found.
        """
        let result = VisionResponseParser.extractJSON(from: input)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Settings"))
    }

    func testExtractJSONFromFenceWithoutLanguage() {
        let input = """
        ```
        [{"label": "Mail", "x": 50, "y": 60, "type": "app"}]
        ```
        """
        let result = VisionResponseParser.extractJSON(from: input)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Mail"))
    }

    func testExtractJSONReturnsNilForNoArray() {
        let result = VisionResponseParser.extractJSON(from: "No JSON here, just text.")
        XCTAssertNil(result)
    }

    func testExtractJSONReturnsNilForMalformedArray() {
        let result = VisionResponseParser.extractJSON(from: "[this is not valid json]")
        XCTAssertNil(result)
    }

    // MARK: - Parsing with Coordinate Scaling

    func testParseScalesCoordinates() {
        // Vision image was 500px wide, window is 410pt wide → scaleX = 0.82
        // Vision image was 1010px tall, window is 890pt tall → scaleY = 0.881
        let response = """
        [
            {"label": "Météo", "x": 100, "y": 200, "type": "app"},
            {"label": "Settings", "x": 300, "y": 400, "type": "app"}
        ]
        """
        let scaleX = 410.0 / 500.0
        let scaleY = 890.0 / 1010.0
        let (elements, _) = VisionResponseParser.parse(
            responseText: response, scaleX: scaleX, scaleY: scaleY
        )
        XCTAssertEqual(elements.count, 2)

        // First element: x=100*0.82=82, y=200*0.881=176.2
        XCTAssertEqual(elements[0].text, "Météo")
        XCTAssertEqual(elements[0].tapX, 100.0 * scaleX, accuracy: 0.01)
        XCTAssertEqual(elements[0].tapY, 200.0 * scaleY, accuracy: 0.01)

        // Second element
        XCTAssertEqual(elements[1].text, "Settings")
        XCTAssertEqual(elements[1].tapX, 300.0 * scaleX, accuracy: 0.01)
    }

    func testParsePrefersLabelOverText() {
        let response = """
        [{"label": "Primary Label", "text": "Secondary", "x": 10, "y": 20, "type": "button"}]
        """
        let (elements, _) = VisionResponseParser.parse(
            responseText: response, scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].text, "Primary Label")
    }

    func testParseFallsBackToTextWhenNoLabel() {
        let response = """
        [{"text": "Fallback Text", "x": 10, "y": 20, "type": "button"}]
        """
        let (elements, _) = VisionResponseParser.parse(
            responseText: response, scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].text, "Fallback Text")
    }

    func testParseSkipsEmptyLabels() {
        let response = """
        [
            {"label": "", "x": 10, "y": 20, "type": "icon"},
            {"label": "Visible", "x": 30, "y": 40, "type": "button"}
        ]
        """
        let (elements, _) = VisionResponseParser.parse(
            responseText: response, scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].text, "Visible")
    }

    // MARK: - Hint Derivation

    func testParseDerivesBackButtonHint() {
        let response = """
        [
            {"label": "<", "x": 30, "y": 50, "type": "back_button"},
            {"label": "Title", "x": 200, "y": 50, "type": "nav_title"}
        ]
        """
        let (_, hints) = VisionResponseParser.parse(
            responseText: response, scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertTrue(hints.contains("has_back_button"))
    }

    func testParseNoHintsWithoutBackButton() {
        let response = """
        [{"label": "Home", "x": 100, "y": 800, "type": "tab"}]
        """
        let (_, hints) = VisionResponseParser.parse(
            responseText: response, scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertFalse(hints.contains("has_back_button"))
    }

    // MARK: - Error Handling

    func testParseReturnsEmptyForMalformedJSON() {
        let (elements, hints) = VisionResponseParser.parse(
            responseText: "totally not json {{{", scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertTrue(elements.isEmpty)
        XCTAssertTrue(hints.isEmpty)
    }

    func testParseReturnsEmptyForEmptyResponse() {
        let (elements, hints) = VisionResponseParser.parse(
            responseText: "", scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertTrue(elements.isEmpty)
        XCTAssertTrue(hints.isEmpty)
    }

    func testParseHandlesMarkdownWrappedResponse() {
        let response = """
        Here are the detected elements:

        ```json
        [
            {"label": "Chrome", "x": 200, "y": 865, "type": "dock_app"},
            {"label": "Search", "x": 355, "y": 840, "type": "button"}
        ]
        ```

        I found 2 elements on the dock.
        """
        let (elements, _) = VisionResponseParser.parse(
            responseText: response, scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0].text, "Chrome")
        XCTAssertEqual(elements[1].text, "Search")
    }
}
