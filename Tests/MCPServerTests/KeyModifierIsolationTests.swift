// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Checks that a chord asks for its modifier once and the next key asks for none, on both delivery paths.
// ABOUTME: Uses a recording key poster: nothing reaches the Mac's keyboard.

import CoreGraphics
import XCTest
import HelperLib
@testable import mirroir_mcp

/// A modifier that leaks turns the next keystroke into a shortcut: Cmd+3
/// followed by "w" would close a window. These tests pin what each call asks
/// the key poster for; `KeyStrokePlannerTests` pins that one press releases
/// what it pressed.
final class KeyModifierIsolationTests: XCTestCase {

    private let windowPID: pid_t = 777
    private let keycode3: UInt16 = 0x14
    private let keycodeV: UInt16 = 0x09

    /// The window path (keys posted to the target's process) when `window` is
    /// true, the HID path (target in front, keys through the event tap) otherwise.
    private func makeInput(window: Bool, keys: RecordingKeyPoster) -> InputSimulation {
        let bridge = StubBridge()
        bridge.processRunning = false
        bridge.frontmost = !window
        bridge.windowInfo = WindowInfo(
            windowID: 4242, position: CGPoint(x: 100, y: 50),
            size: CGSize(width: 410, height: 898), pid: windowPID)
        return InputSimulation(bridge: bridge, keyboardLayout: .usQWERTY,
                               keyPoster: keys, windowPoster: window ? RecordingWindowPoster() : nil)
    }

    private func plain(_ character: Character) throws -> CGKeySequence {
        try XCTUnwrap(IPhoneKeyboardLayout.usQWERTY.keySequence(for: character))
    }

    private func assertAChordDoesNotMarkTheNextKey(window: Bool) throws {
        let keys = RecordingKeyPoster()
        let input = makeInput(window: window, keys: keys)

        XCTAssertTrue(input.pressKey(keyName: "3", modifiers: ["command"]).success)
        XCTAssertTrue(input.typeText("w").success)

        XCTAssertEqual(keys.keycodes, [keycode3])
        XCTAssertEqual(keys.flags, [.maskCommand], "the chord asks for Command once")
        let w = try plain("w")
        XCTAssertEqual(keys.sequences, [w])
        XCTAssertTrue(w.steps.allSatisfy { $0.flags.isEmpty }, "the next key asks for no modifier")
        let expectedTarget: pid_t? = window ? windowPID : nil
        XCTAssertEqual(keys.targets, [expectedTarget, expectedTarget])
    }

    func testWindowPathAChordDoesNotMarkTheNextKey() throws {
        try assertAChordDoesNotMarkTheNextKey(window: true)
    }

    func testHIDPathAChordDoesNotMarkTheNextKey() throws {
        try assertAChordDoesNotMarkTheNextKey(window: false)
    }

    func testAShiftedCharacterDoesNotMarkThePlainOneAfterIt() throws {
        for window in [true, false] {
            let keys = RecordingKeyPoster()
            XCTAssertTrue(makeInput(window: window, keys: keys).typeText("Ab").success)

            XCTAssertEqual(keys.sequences.count, 2)
            XCTAssertEqual(keys.sequences.first?.steps.map(\.flags), [.maskShift])
            XCTAssertEqual(keys.sequences.last, try plain("b"))
            XCTAssertEqual(keys.sequences.last?.steps.map(\.flags), [CGEventFlags()])
        }
    }

    /// Shake is a chord like any other, so it goes through the same poster and
    /// gets the same release.
    func testShakeGoesThroughTheKeyPoster() {
        let keys = RecordingKeyPoster()
        XCTAssertTrue(makeInput(window: true, keys: keys).shake().success)

        XCTAssertEqual(keys.keycodes, [CGEventInput.shakeKeycode])
        XCTAssertEqual(keys.flags, [CGEventInput.shakeFlags])
        XCTAssertEqual(keys.targets, [windowPID])
    }

    func testAPasteChordDoesNotMarkTheKeyAfterIt() throws {
        let keys = RecordingKeyPoster()
        let input = makeInput(window: true, keys: keys)

        XCTAssertTrue(input.pressKey(keyName: "v", modifiers: ["command"]).success)
        XCTAssertTrue(input.typeText("a").success)

        XCTAssertEqual(keys.keycodes, [keycodeV])
        XCTAssertEqual(keys.flags, [.maskCommand])
        XCTAssertEqual(keys.sequences, [try plain("a")])
    }
}
