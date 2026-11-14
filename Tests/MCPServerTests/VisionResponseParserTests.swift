/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
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

    // MARK: - Vision Indicator Normalization

    func testIndicatorSuffixSplitsIntoTwoElements() {
        // "chevron" suffix should split into label + ">" (if indicators are loaded)
        // The normalizer checks against loaded indicators from vision-indicators.md.
        // With no indicators loaded (test environment), the text passes through unchanged.
        let response = """
        [{"label": "Entraînements chevron", "x": 200, "y": 400}]
        """
        let (elements, _) = VisionResponseParser.parse(
            responseText: response, scaleX: 1.0, scaleY: 1.0
        )
        // If vision-indicators.md is found (sibling repo), we get 2 elements.
        // If not found (CI), we get 1 element with the full text.
        XCTAssertGreaterThanOrEqual(elements.count, 1,
            "Should produce at least 1 element")
        if elements.count == 2 {
            XCTAssertEqual(elements[0].text, "Entraînements")
            XCTAssertEqual(elements[1].text, ">")
        } else {
            XCTAssertEqual(elements[0].text, "Entraînements chevron")
        }
    }

    func testNoIndicatorSuffixPassesThrough() {
        let response = """
        [{"label": "Settings", "x": 200, "y": 300}]
        """
        let (elements, _) = VisionResponseParser.parse(
            responseText: response, scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].text, "Settings")
    }

    // MARK: - Multi-Format Tolerance

    func testParseNestedCenterCoordinates() {
        let response = """
        [{"label": "Settings", "center": {"x": 200, "y": 300}, "type": "app"}]
        """
        let (elements, _) = VisionResponseParser.parse(
            responseText: response, scaleX: 0.82, scaleY: 0.88
        )
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].tapX, 200.0 * 0.82, accuracy: 0.01)
        XCTAssertEqual(elements[0].tapY, 300.0 * 0.88, accuracy: 0.01)
    }

    func testParseNameFieldFallback() {
        let response = """
        [{"name": "Mail", "x": 100, "y": 150, "type": "app"}]
        """
        let (elements, _) = VisionResponseParser.parse(
            responseText: response, scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].text, "Mail")
    }

    func testParseKindFieldFallback() {
        let response = """
        [{"label": "Météo", "x": 100, "y": 200, "kind": "app_icon"}]
        """
        let (elements, _) = VisionResponseParser.parse(
            responseText: response, scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].text, "Météo")
    }

    func testParseMixedValidAndMalformedElements() {
        let response = """
        [
            {"label": "Good", "x": 100, "y": 200, "type": "app"},
            {"label": "NoCoords", "type": "button"},
            {"label": "AlsoGood", "x": 300, "y": 400, "type": "tab"}
        ]
        """
        let (elements, _) = VisionResponseParser.parse(
            responseText: response, scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0].text, "Good")
        XCTAssertEqual(elements[1].text, "AlsoGood")
    }

    // MARK: - Truncated JSON Recovery

    func testExtractJSONRecoversTruncatedArray() {
        let truncated = """
        [{"label": "A", "x": 1, "y": 2}, {"label": "B", "x": 3, "y": 4}, {"label": "C", "x"
        """
        let result = VisionResponseParser.extractJSON(from: truncated)
        XCTAssertNotNil(result, "Should recover valid prefix from truncated JSON")
        if let json = result,
           let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            XCTAssertEqual(arr.count, 2, "Should recover A and B, dropping truncated C")
        }
    }

    func testExtractJSONRecoversTruncatedWithNewlines() {
        let truncated = """
        [
          {"label": "Météo", "x": 98, "y": 352, "type": "app"},
          {"label": "Horloge", "x": 303, "y": 352, "type": "app"},
          {"label": "Cal
        """
        let result = VisionResponseParser.extractJSON(from: truncated)
        XCTAssertNotNil(result, "Should recover valid elements from truncated response")
    }

    func testParseRecoversTruncatedResponse() {
        let truncated = """
        [
            {"label": "Home", "x": 50, "y": 800, "type": "tab"},
            {"label": "Search", "x": 150, "y": 800, "type": "tab"},
            {"label": "Prof
        """
        let (elements, _) = VisionResponseParser.parse(
            responseText: truncated, scaleX: 1.0, scaleY: 1.0
        )
        XCTAssertEqual(elements.count, 2, "Should parse Home and Search from truncated response")
        XCTAssertEqual(elements[0].text, "Home")
        XCTAssertEqual(elements[1].text, "Search")
    }
}
