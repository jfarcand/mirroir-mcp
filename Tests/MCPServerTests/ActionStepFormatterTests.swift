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
// ABOUTME: Unit tests for ActionStepFormatter: action type to markdown step mapping.
// ABOUTME: Covers all step types including tap, swipe, type, remember, screenshot, assert, and edge cases.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ActionStepFormatterTests: XCTestCase {

    func testTapActionType() {
        let step = ActionStepFormatter.format(actionType: "tap", arrivedVia: "More Info")
        XCTAssertEqual(step, "Tap \"More Info\"")
    }

    func testSwipeActionType() {
        let step = ActionStepFormatter.format(actionType: "swipe", arrivedVia: "up")
        XCTAssertEqual(step, "swipe: \"up\"")
    }

    func testTypeActionType() {
        let step = ActionStepFormatter.format(actionType: "type", arrivedVia: "hello")
        XCTAssertEqual(step, "Type \"hello\"")
    }

    func testPressKeyActionType() {
        let step = ActionStepFormatter.format(actionType: "press_key", arrivedVia: "return")
        XCTAssertEqual(step, "Press **return**")
    }

    func testScrollToActionType() {
        let step = ActionStepFormatter.format(actionType: "scroll_to", arrivedVia: "About")
        XCTAssertEqual(step, "Scroll until \"About\" is visible")
    }

    func testLongPressActionType() {
        let step = ActionStepFormatter.format(actionType: "long_press", arrivedVia: "photo")
        XCTAssertEqual(step, "long_press: \"photo\"")
    }

    func testNilActionTypeDefaultsToTap() {
        let step = ActionStepFormatter.format(actionType: nil, arrivedVia: "General")
        XCTAssertEqual(step, "Tap \"General\"",
            "Missing actionType with arrivedVia should default to tap")
    }

    func testNilArrivedViaReturnsNil() {
        let step = ActionStepFormatter.format(actionType: "tap", arrivedVia: nil)
        XCTAssertNil(step, "No arrivedVia should produce no action step")
    }

    func testEmptyArrivedViaReturnsNil() {
        let step = ActionStepFormatter.format(actionType: "tap", arrivedVia: "")
        XCTAssertNil(step, "Empty arrivedVia should produce no action step")
    }

    func testUnknownActionTypeDefaultsToTap() {
        let step = ActionStepFormatter.format(actionType: "unknown_action", arrivedVia: "Button")
        XCTAssertEqual(step, "Tap \"Button\"",
            "Unknown actionType should default to tap")
    }

    // MARK: - New Step Types

    func testRememberActionType() {
        let step = ActionStepFormatter.format(actionType: "remember", arrivedVia: "Note the iOS version number")
        XCTAssertEqual(step, "Remember: Note the iOS version number")
    }

    func testScreenshotActionType() {
        let step = ActionStepFormatter.format(actionType: "screenshot", arrivedVia: "version_screen")
        XCTAssertEqual(step, "Screenshot: \"version_screen\"")
    }

    func testAssertVisibleActionType() {
        let step = ActionStepFormatter.format(actionType: "assert_visible", arrivedVia: "iOS Version")
        XCTAssertEqual(step, "Verify \"iOS Version\" is visible")
    }

    func testAssertNotVisibleActionType() {
        let step = ActionStepFormatter.format(actionType: "assert_not_visible", arrivedVia: "Error")
        XCTAssertEqual(step, "Verify \"Error\" is not visible")
    }

    func testOpenURLActionType() {
        let step = ActionStepFormatter.format(actionType: "open_url", arrivedVia: "https://example.com")
        XCTAssertEqual(step, "Open URL: https://example.com")
    }

    // MARK: - Self-Sufficient Actions

    func testPressHomeWithoutArrivedVia() {
        let step = ActionStepFormatter.format(actionType: "press_home", arrivedVia: nil)
        XCTAssertEqual(step, "Press Home",
            "press_home should produce a step even without arrivedVia")
    }

    func testPressHomeWithEmptyArrivedVia() {
        let step = ActionStepFormatter.format(actionType: "press_home", arrivedVia: "")
        XCTAssertEqual(step, "Press Home",
            "press_home should produce a step even with empty arrivedVia")
    }

    func testPressHomeWithArrivedVia() {
        let step = ActionStepFormatter.format(actionType: "press_home", arrivedVia: "anything")
        XCTAssertEqual(step, "Press Home",
            "press_home should ignore arrivedVia")
    }

    // MARK: - Nil/Nil Edge Case

    func testNilBothReturnsNil() {
        let step = ActionStepFormatter.format(actionType: nil, arrivedVia: nil)
        XCTAssertNil(step, "Both nil should produce no step")
    }

    func testEmptyBothReturnsNil() {
        let step = ActionStepFormatter.format(actionType: "", arrivedVia: "")
        XCTAssertNil(step, "Both empty should produce no step")
    }

    // MARK: - resolveLabel

    func testResolveLabelExactMatch() {
        let elements = [
            TapPoint(text: "General", tapX: 205, tapY: 200, confidence: 0.95),
            TapPoint(text: "About", tapX: 205, tapY: 280, confidence: 0.95),
        ]

        let result = ActionStepFormatter.resolveLabel(arrivedVia: "General", elements: elements)
        XCTAssertEqual(result, "General")
    }

    func testResolveLabelCaseInsensitive() {
        let elements = [
            TapPoint(text: "Privacy & Security", tapX: 205, tapY: 200, confidence: 0.95),
        ]

        let result = ActionStepFormatter.resolveLabel(arrivedVia: "privacy & security", elements: elements)
        XCTAssertEqual(result, "Privacy & Security",
            "Should return element's text with proper casing")
    }

    func testResolveLabelContainment() {
        let elements = [
            TapPoint(text: "Software Update", tapX: 205, tapY: 200, confidence: 0.95),
        ]

        let result = ActionStepFormatter.resolveLabel(arrivedVia: "software", elements: elements)
        XCTAssertEqual(result, "Software Update",
            "Should match when arrivedVia is substring of element text")
    }

    func testResolveLabelNoMatch() {
        let elements = [
            TapPoint(text: "General", tapX: 205, tapY: 200, confidence: 0.95),
        ]

        let result = ActionStepFormatter.resolveLabel(arrivedVia: "Unknown Button", elements: elements)
        XCTAssertEqual(result, "Unknown Button",
            "Should return original when no match found")
    }
}
