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
// ABOUTME: Unit tests for CalibrationScroller: element deduplication logic.
// ABOUTME: Tests the pure deduplication function with synthetic OCR data.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class CalibrationScrollerTests: XCTestCase {

    // MARK: - Helpers

    private func point(
        _ text: String, x: Double = 200, y: Double = 400
    ) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    // MARK: - Deduplication

    func testDeduplicateByTextKeepsLastOccurrence() {
        // Same text "General" appears at two Y positions (before and after scroll)
        let elements = [
            point("General", x: 100, y: 300),
            point("Privacy", x: 100, y: 400),
            point("General", x: 100, y: 150),  // duplicate at new position
        ]

        let result = CalibrationScroller.deduplicateByText(elements)

        XCTAssertEqual(result.count, 2,
            "Should deduplicate by text, keeping unique texts only")
        let texts = Set(result.map { $0.text })
        XCTAssertTrue(texts.contains("General"))
        XCTAssertTrue(texts.contains("Privacy"))
    }

    func testDeduplicateByTextPreservesLastCoordinates() {
        let elements = [
            point("General", x: 100, y: 300),
            point("General", x: 100, y: 150),  // later entry, different Y
        ]

        let result = CalibrationScroller.deduplicateByText(elements)

        XCTAssertEqual(result.count, 1)
        // The last occurrence should be kept (y=150)
        XCTAssertEqual(result[0].tapY, 150,
            "Should keep the latest coordinates for duplicated text")
    }

    func testDeduplicateByTextSortsByY() {
        let elements = [
            point("C", x: 100, y: 500),
            point("A", x: 100, y: 100),
            point("B", x: 100, y: 300),
        ]

        let result = CalibrationScroller.deduplicateByText(elements)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].text, "A")
        XCTAssertEqual(result[1].text, "B")
        XCTAssertEqual(result[2].text, "C")
    }

    func testDeduplicateEmptyInput() {
        let result = CalibrationScroller.deduplicateByText([])
        XCTAssertTrue(result.isEmpty)
    }

    func testDeduplicateAllUnique() {
        let elements = [
            point("General", x: 100, y: 300),
            point("Privacy", x: 100, y: 400),
            point("About", x: 100, y: 500),
        ]

        let result = CalibrationScroller.deduplicateByText(elements)

        XCTAssertEqual(result.count, 3,
            "All unique texts should be preserved")
    }

    func testDeduplicateMultipleDuplicates() {
        let elements = [
            point("A", x: 100, y: 100),
            point("B", x: 100, y: 200),
            point("A", x: 100, y: 300),
            point("B", x: 100, y: 400),
            point("C", x: 100, y: 500),
        ]

        let result = CalibrationScroller.deduplicateByText(elements)

        XCTAssertEqual(result.count, 3,
            "Should have 3 unique texts: A, B, C")
    }
}
