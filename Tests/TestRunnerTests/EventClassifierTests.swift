// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for EventClassifier: mouse gesture classification and key event mapping.
// ABOUTME: Covers tap detection, swipe directions, long press, hold time, labels, and modifiers.

import CoreGraphics
import HelperLib
import XCTest
@testable import mirroir_mcp

final class EventClassifierTests: XCTestCase {

    // MARK: - Mouse Classification: Taps

    func testTapSmallMovement() {
        let result = EventClassifier.classifyMouse(
            downX: 100, downY: 200, upX: 102, upY: 201, holdSeconds: 0.1)
        if case .tap = result {
            // expected
        } else {
            XCTFail("Expected .tap, got \(result)")
        }
    }

    func testTapNoMovement() {
        let result = EventClassifier.classifyMouse(
            downX: 100, downY: 200, upX: 100, upY: 200, holdSeconds: 0.05)
        if case .tap = result {
            // expected
        } else {
            XCTFail("Expected .tap, got \(result)")
        }
    }

    func testTapSlightlyBeyondThresholdButBelowSwipe() {
        // Movement between tap threshold (5) and swipe threshold (30)
        // Should classify as tap (imprecise click)
        let result = EventClassifier.classifyMouse(
            downX: 100, downY: 200, upX: 115, upY: 200, holdSeconds: 0.1)
        if case .tap = result {
            // expected
        } else {
            XCTFail("Expected .tap for small movement, got \(result)")
        }
    }

    // MARK: - Mouse Classification: Long Press

    func testLongPressNoMovement() {
        let result = EventClassifier.classifyMouse(
            downX: 100, downY: 200, upX: 100, upY: 200, holdSeconds: 0.8)
        if case .longPress = result {
            // expected
        } else {
            XCTFail("Expected .longPress, got \(result)")
        }
    }

    func testLongPressAtThreshold() {
        let result = EventClassifier.classifyMouse(
            downX: 100, downY: 200, upX: 101, upY: 201, holdSeconds: 0.5)
        if case .longPress = result {
            // expected
        } else {
            XCTFail("Expected .longPress at exact threshold, got \(result)")
        }
    }

    func testLongPressTinyMovement() {
        let result = EventClassifier.classifyMouse(
            downX: 100, downY: 200, upX: 103, upY: 202, holdSeconds: 1.0)
        if case .longPress = result {
            // expected
        } else {
            XCTFail("Expected .longPress with tiny movement, got \(result)")
        }
    }

    // MARK: - Mouse Classification: Swipes

    func testSwipeUp() {
        let result = EventClassifier.classifyMouse(
            downX: 100, downY: 400, upX: 100, upY: 100, holdSeconds: 0.3)
        if case .swipe(let direction) = result {
            XCTAssertEqual(direction, "up")
        } else {
            XCTFail("Expected .swipe(up), got \(result)")
        }
    }

    func testSwipeDown() {
        let result = EventClassifier.classifyMouse(
            downX: 100, downY: 100, upX: 100, upY: 400, holdSeconds: 0.3)
        if case .swipe(let direction) = result {
            XCTAssertEqual(direction, "down")
        } else {
            XCTFail("Expected .swipe(down), got \(result)")
        }
    }

    func testSwipeLeft() {
        let result = EventClassifier.classifyMouse(
            downX: 300, downY: 200, upX: 50, upY: 200, holdSeconds: 0.2)
        if case .swipe(let direction) = result {
            XCTAssertEqual(direction, "left")
        } else {
            XCTFail("Expected .swipe(left), got \(result)")
        }
    }

    func testSwipeRight() {
        let result = EventClassifier.classifyMouse(
            downX: 50, downY: 200, upX: 300, upY: 200, holdSeconds: 0.2)
        if case .swipe(let direction) = result {
            XCTAssertEqual(direction, "right")
        } else {
            XCTFail("Expected .swipe(right), got \(result)")
        }
    }

    func testSwipeDiagonalFavorsVertical() {
        // More vertical movement than horizontal
        let result = EventClassifier.classifyMouse(
            downX: 100, downY: 400, upX: 120, upY: 100, holdSeconds: 0.3)
        if case .swipe(let direction) = result {
            XCTAssertEqual(direction, "up")
        } else {
            XCTFail("Expected .swipe(up) for mostly-vertical diagonal, got \(result)")
        }
    }

    func testSwipeDiagonalFavorsHorizontal() {
        // More horizontal movement than vertical
        let result = EventClassifier.classifyMouse(
            downX: 50, downY: 200, upX: 350, upY: 220, holdSeconds: 0.3)
        if case .swipe(let direction) = result {
            XCTAssertEqual(direction, "right")
        } else {
            XCTFail("Expected .swipe(right) for mostly-horizontal diagonal, got \(result)")
        }
    }

    // MARK: - Special Key Names

    func testSpecialKeyReturn() {
        XCTAssertEqual(EventClassifier.specialKeyName(for: 36), "return")
    }

    func testSpecialKeyEscape() {
        XCTAssertEqual(EventClassifier.specialKeyName(for: 53), "escape")
    }

    func testSpecialKeyTab() {
        XCTAssertEqual(EventClassifier.specialKeyName(for: 48), "tab")
    }

    func testSpecialKeyDelete() {
        XCTAssertEqual(EventClassifier.specialKeyName(for: 51), "delete")
    }

    func testSpecialKeySpace() {
        XCTAssertEqual(EventClassifier.specialKeyName(for: 49), "space")
    }

    func testSpecialKeyArrows() {
        XCTAssertEqual(EventClassifier.specialKeyName(for: 126), "up")
        XCTAssertEqual(EventClassifier.specialKeyName(for: 125), "down")
        XCTAssertEqual(EventClassifier.specialKeyName(for: 123), "left")
        XCTAssertEqual(EventClassifier.specialKeyName(for: 124), "right")
    }

    func testRegularKeyNotSpecial() {
        // 'a' key is keyCode 0, not in the special map
        XCTAssertNil(EventClassifier.specialKeyName(for: 0))
    }

    // MARK: - Modifier Extraction

    func testExtractNoModifiers() {
        let mods = EventClassifier.extractModifiers(CGEventFlags())
        XCTAssertTrue(mods.isEmpty)
    }

    func testExtractCommand() {
        let mods = EventClassifier.extractModifiers(.maskCommand)
        XCTAssertEqual(mods, ["command"])
    }

    func testExtractShift() {
        let mods = EventClassifier.extractModifiers(.maskShift)
        XCTAssertEqual(mods, ["shift"])
    }

    func testExtractMultipleModifiers() {
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        let mods = EventClassifier.extractModifiers(flags)
        XCTAssertTrue(mods.contains("command"))
        XCTAssertTrue(mods.contains("shift"))
        XCTAssertEqual(mods.count, 2)
    }

    func testExtractAllModifiers() {
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        let mods = EventClassifier.extractModifiers(flags)
        XCTAssertEqual(mods.count, 4)
        XCTAssertTrue(mods.contains("command"))
        XCTAssertTrue(mods.contains("shift"))
        XCTAssertTrue(mods.contains("option"))
        XCTAssertTrue(mods.contains("control"))
    }
    // MARK: - Hold Time

    func testHoldSecondsComesFromEventTimestamps() {
        // A 60ms posted tap whose mouse-up was handled 700ms later (the
        // recorder read the screen on mouse-down) still holds for 60ms.
        let hold = EventClassifier.holdSeconds(
            downTimestamp: 5_000_000_000, upTimestamp: 5_060_000_000)
        XCTAssertEqual(hold, 0.06, accuracy: 0.000_001)
        if case .tap = EventClassifier.classifyMouse(
            downX: 67, downY: 536, upX: 67, upY: 536, holdSeconds: hold) {
            // expected
        } else {
            XCTFail("A 60ms hold must classify as a tap")
        }
    }

    func testHoldSecondsIsZeroForOutOfOrderTimestamps() {
        XCTAssertEqual(
            EventClassifier.holdSeconds(downTimestamp: 9, upTimestamp: 3), 0)
    }

    // MARK: - Nearest Label

    func testNearestLabelPicksClosestTextWithinDistance() {
        let elements = [
            TapPoint(text: "7", tapX: 67, tapY: 536, confidence: 1),
            TapPoint(text: "8", tapX: 165, tapY: 535, confidence: 1),
        ]
        XCTAssertEqual(
            EventClassifier.nearestLabel(x: 70, y: 540, in: elements, maxDistance: 30), "7")
        XCTAssertNil(
            EventClassifier.nearestLabel(x: 120, y: 700, in: elements, maxDistance: 30))
    }

    func testNearestLabelSkipsDetectorIconPlaceholder() {
        // The Calculator's "3" key OCR missed: only the detector's icon sits
        // there, and its placeholder text is no label a replay could find.
        let elements = [
            TapPoint(text: CoreMLElementDetector.iconLabel, tapX: 285, tapY: 743, confidence: 1),
            TapPoint(text: "+", tapX: 360, tapY: 734, confidence: 1),
        ]
        XCTAssertNil(
            EventClassifier.nearestLabel(x: 262, y: 730, in: elements, maxDistance: 30))
        XCTAssertEqual(
            EventClassifier.nearestLabel(x: 350, y: 735, in: elements, maxDistance: 30), "+")
    }
}
