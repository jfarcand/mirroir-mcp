// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests InputSimulation.typeText's clipboard wiring: no verifier fails a paste, the user's
// ABOUTME: clipboard is restored exactly once whether every paste lands or one fails.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

final class TypeTextPasteWiringTests: XCTestCase {

    /// What the user had copied before the call.
    private let userClipboard = "copied by the user"

    /// A connected target that is not a running process: focusing only calls the
    /// stub's activate(), so nothing on the Mac running the tests is brought forward.
    private func makeInput(phone: SimulatedPhone, verifier: (any ScreenDescribing)?) -> InputSimulation {
        let bridge = StubBridge()
        bridge.processRunning = false
        return InputSimulation(bridge: bridge, keyboardLayout: .usQWERTY,
                               pasteVerifier: verifier,
                               keyPoster: phone, pasteboard: phone.pasteboard)
    }

    func testWithoutAPasteVerifierTextThatNeedsAPasteFails() {
        let phone = SimulatedPhone(clipboard: userClipboard)
        let input = makeInput(phone: phone, verifier: nil)

        let result = input.typeText("日本")

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("Could not read the screen") ?? false,
                      result.error ?? "nil")
        XCTAssertEqual(phone.pasteCount, 0, "an unverifiable paste is never sent")
        XCTAssertEqual(phone.pasteboard.writes, [userClipboard], "restored exactly once")
        XCTAssertEqual(phone.pasteboard.contents, userClipboard)
    }

    func testClipboardIsRestoredOnceAfterEveryPasteIsConfirmed() {
        let phone = SimulatedPhone(clipboard: userClipboard)
        let input = makeInput(phone: phone, verifier: PhoneScreen(phone: phone))

        let result = input.typeText("日a本")

        XCTAssertTrue(result.success, result.error ?? "nil")
        XCTAssertEqual(phone.fieldText, "日a本")
        XCTAssertEqual(phone.pasteCount, 2, "one paste per unmappable run")
        XCTAssertEqual(phone.pasteboard.writes, ["日", "本", userClipboard],
                       "the restore is the single write after the last paste")
        XCTAssertEqual(phone.pasteboard.contents, userClipboard)
    }

    func testClipboardIsRestoredOnceWhenAPasteFails() {
        let phone = SimulatedPhone(clipboard: userClipboard)
        phone.refusePaste = true
        let input = makeInput(phone: phone, verifier: PhoneScreen(phone: phone))

        let result = input.typeText("日a本")

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("not confirmed: \"日a本\"") ?? false,
                      result.error ?? "nil")
        XCTAssertEqual(phone.pasteboard.writes, ["日", userClipboard],
                       "the failed paste stops the entry, then the clipboard is restored once")
        XCTAssertEqual(phone.pasteboard.contents, userClipboard)
    }

    func testKeyedTextLeavesTheClipboardUntouched() {
        let phone = SimulatedPhone(clipboard: userClipboard)
        let input = makeInput(phone: phone, verifier: nil)

        let result = input.typeText("abc")

        XCTAssertTrue(result.success, result.error ?? "nil")
        XCTAssertEqual(phone.fieldText, "abc")
        XCTAssertTrue(phone.pasteboard.writes.isEmpty)
    }
}

// MARK: - Test doubles

/// The Mac pasteboard as a value: records every write instead of touching the
/// real general pasteboard the developer running the tests is using.
private final class RecordingPasteboard: PasteboardAccessing, @unchecked Sendable {
    private(set) var contents: String?
    private(set) var writes: [String] = []

    init(contents: String?) {
        self.contents = contents
    }

    func string() -> String? { contents }

    func replaceContents(with text: String) -> Bool {
        writes.append(text)
        contents = text
        return true
    }
}

/// Stands in for the iPhone's focused text field: key events type their
/// character into it, and Cmd+V pastes the pasteboard into it (Universal
/// Clipboard modelled as instant). No event reaches the real HID event tap.
private final class SimulatedPhone: KeyEventPosting, @unchecked Sendable {
    let pasteboard: RecordingPasteboard
    private(set) var fieldText = ""
    private(set) var pasteCount = 0
    /// When true, posting Cmd+V fails, as a refused CGEvent does.
    var refusePaste = false

    /// Characters the tests type with keys, resolved back from their key sequence.
    private let keyedCharacters: [Character] = Array("abcdefghijklmnopqrstuvwxyz")
    private let layout = IPhoneKeyboardLayout.usQWERTY

    init(clipboard: String) {
        pasteboard = RecordingPasteboard(contents: clipboard)
    }

    func postKey(keycode: UInt16, flags: CGEventFlags) -> Bool {
        guard flags.contains(.maskCommand), keycode == CGKeyMap.lookup("v")?.keycode else {
            return true
        }
        if refusePaste { return false }
        pasteCount += 1
        fieldText += pasteboard.contents ?? ""
        return true
    }

    func postKeySequence(_ sequence: CGKeySequence) -> Bool {
        guard let char = keyedCharacters.first(where: { layout.keySequence(for: $0) == sequence }) else {
            return false
        }
        fieldText.append(char)
        return true
    }
}

/// The paste verifier: OCR of the simulated phone reads its text field back.
private struct PhoneScreen: ScreenDescribing, @unchecked Sendable {
    let phone: SimulatedPhone

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
        ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: phone.fieldText, tapX: 200, tapY: 100, confidence: 0.95)],
            screenshotBase64: "")
    }
}
