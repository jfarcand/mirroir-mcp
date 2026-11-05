// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests which input InputSimulation posts straight to the target's window and which keeps the HID path.
// ABOUTME: Pins taps and keys to the window poster with no activation, and swipes and drags off it.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

final class WindowDeliveryTests: XCTestCase {

    private let windowID: CGWindowID = 4242
    private let windowPID: pid_t = 777

    /// A connected target that is NOT front and is not a running process:
    /// any input that needed activation would be refused, and nothing on the
    /// Mac running the tests is brought forward.
    private func makeInput(
        poster: RecordingWindowPoster?, keys: RecordingKeyPoster = RecordingKeyPoster(),
        windowID: CGWindowID? = nil
    ) -> InputSimulation {
        let bridge = StubBridge()
        bridge.processRunning = false
        bridge.frontmost = false
        bridge.windowInfo = WindowInfo(
            windowID: windowID ?? self.windowID, position: CGPoint(x: 100, y: 50),
            size: CGSize(width: 410, height: 898), pid: windowPID)
        return InputSimulation(bridge: bridge, keyboardLayout: .usQWERTY,
                               keyPoster: keys, windowPoster: poster)
    }

    // MARK: - Pointing

    func testATapIsPostedToTheWindowWithoutActivatingTheTarget() {
        let poster = RecordingWindowPoster()
        XCTAssertNil(makeInput(poster: poster).tap(x: 200, y: 300, cursorMode: nil))
        let point = CGPoint(x: 200, y: 300)
        XCTAssertEqual(poster.buttons, [
            .init(down: true, point: point, clickCount: 1, windowID: windowID),
            .init(down: false, point: point, clickCount: 1, windowID: windowID),
        ], "window-local point, addressed to the window")
        XCTAssertEqual(poster.pauses, [CGEventInput.clickHoldUs])
    }

    func testADoubleTapNumbersItsSecondClick() {
        let poster = RecordingWindowPoster()
        XCTAssertNil(makeInput(poster: poster).doubleTap(x: 10, y: 20, cursorMode: nil))
        XCTAssertEqual(poster.buttons.map(\.clickCount), [1, 1, 2, 2])
        XCTAssertEqual(poster.buttons.map(\.down), [true, false, true, false])
    }

    func testALongPressHoldsForItsDuration() {
        let poster = RecordingWindowPoster()
        XCTAssertNil(makeInput(poster: poster).longPress(x: 10, y: 20, durationMs: 800, cursorMode: nil))
        XCTAssertEqual(poster.buttons.map(\.down), [true, false])
        XCTAssertEqual(poster.pauses, [800_000])
    }

    func testWithoutAWindowPosterATapNeedsTheFront() {
        let message = makeInput(poster: nil).tap(x: 200, y: 300, cursorMode: nil)
        XCTAssertNotNil(message, "the HID path refuses a target it cannot bring to the front")
    }

    func testAWindowTheWindowServerDidNotNameKeepsTheHIDPath() {
        let poster = RecordingWindowPoster()
        let message = makeInput(poster: poster, windowID: 0).tap(x: 200, y: 300, cursorMode: nil)
        XCTAssertNotNil(message)
        XCTAssertTrue(poster.buttons.isEmpty, "no window ID, nothing to address")
    }

    /// Drag events and records lose their intermediate points on macOS 26: a
    /// drag stays on the HID path, which needs the front. Refused here, and the
    /// window poster is never used.
    func testADragNeverUsesTheWindowPoster() {
        let poster = RecordingWindowPoster()
        let input = makeInput(poster: poster)
        XCTAssertNotNil(input.drag(fromX: 200, fromY: 600, toX: 200, toY: 200,
                                   durationMs: 300, cursorMode: nil))
        XCTAssertTrue(poster.buttons.isEmpty)
        XCTAssertTrue(poster.keyFocusWindows.isEmpty)
    }

    /// A swipe is scroll events: addressed to the window, they scroll it with
    /// the mirror covered and another app in front (measured on an XR, macOS 26.5).
    /// The window's PID here is one no process has, so the events go nowhere.
    func testASwipeGoesToTheWindowWithoutActivatingTheTarget() {
        let poster = RecordingWindowPoster()
        let bridge = StubBridge()
        bridge.processRunning = false
        bridge.frontmost = false
        bridge.windowInfo = WindowInfo(windowID: windowID, position: CGPoint(x: 100, y: 50),
                                       size: CGSize(width: 410, height: 898), pid: 99_999)
        let input = InputSimulation(bridge: bridge, keyboardLayout: .usQWERTY,
                                    keyPoster: RecordingKeyPoster(), windowPoster: poster)
        XCTAssertNil(input.swipe(fromX: 200, fromY: 600, toX: 200, toY: 200,
                                 durationMs: 100, cursorMode: nil))
        XCTAssertEqual(poster.keyFocusWindows, [windowID], "one focus record for the gesture")
        XCTAssertFalse(poster.stampedPoints.isEmpty)
        XCTAssertEqual(Set(poster.stampedPoints.map(\.x)), [200])
        XCTAssertEqual(Set(poster.stampedPoints.map(\.y)), [400], "every event at the midpoint")
    }

    func testWithoutEventStampingASwipeNeedsTheFront() {
        let poster = RecordingWindowPoster()
        poster.canStampEvents = false
        XCTAssertNotNil(makeInput(poster: poster).swipe(fromX: 200, fromY: 600, toX: 200, toY: 200,
                                                        durationMs: 100, cursorMode: nil))
        XCTAssertTrue(poster.stampedPoints.isEmpty)
    }

    // MARK: - Keys

    func testKeysGoToTheTargetProcessAfterOneKeyFocusRecord() {
        let poster = RecordingWindowPoster()
        let keys = RecordingKeyPoster()
        let input = makeInput(poster: poster, keys: keys)

        XCTAssertTrue(input.pressKey(keyName: "return", modifiers: []).success)
        XCTAssertTrue(input.typeText("ab").success)

        XCTAssertEqual(poster.keyFocusWindows, [windowID, windowID], "one focus record per call")
        XCTAssertEqual(keys.targets, [windowPID, windowPID, windowPID])
    }

    func testAKeyFocusRecordThatIsNotPostedSendsNoKeys() {
        let poster = RecordingWindowPoster()
        poster.focusSucceeds = false
        let keys = RecordingKeyPoster()

        let result = makeInput(poster: poster, keys: keys).pressKey(keyName: "return", modifiers: [])

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Could not give 'iphone' keyboard focus. No input was sent.")
        XCTAssertTrue(keys.targets.isEmpty)
    }

    func testWithoutAWindowPosterKeysNeedTheFront() {
        let keys = RecordingKeyPoster()
        let result = makeInput(poster: nil, keys: keys).pressKey(keyName: "return", modifiers: [])
        XCTAssertFalse(result.success, "the HID path refuses a target it cannot bring to the front")
        XCTAssertTrue(keys.targets.isEmpty)
    }

    // MARK: - Live entry points

    func testTheSkyLightEntryPointsResolveOnThisMac() {
        XCTAssertNotNil(SkyLightWindowPoster.live,
                        "SLPSPostEventRecordTo and GetProcessForPID must resolve on supported macOS")
    }

    /// `test`, `compile` and `record` build their input through this factory,
    /// so the CLI posts to the window exactly like the MCP server does.
    func testEveryMirrorEntryPointGetsTheWindowPoster() {
        XCTAssertNotNil(IPhoneMirroringTarget.input(bridge: MirroringBridge()).windowPoster)
    }
}
