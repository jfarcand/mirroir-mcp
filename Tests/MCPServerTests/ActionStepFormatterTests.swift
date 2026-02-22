// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ActionStepFormatter: action type to markdown step mapping.
// ABOUTME: Covers tap, swipe, type, press_key, scroll_to, long_press, and edge cases.

import XCTest
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
}
