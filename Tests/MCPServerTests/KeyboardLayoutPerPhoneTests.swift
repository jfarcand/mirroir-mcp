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
// ABOUTME: Tests typing for two iPhones with different keyboards (an XR on Canadian-CSA, an iPhone 16 on US).
// ABOUTME: Disputed characters are pasted until the phone's layout is given; a wrong answer is caught and forgotten.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

final class KeyboardLayoutPerPhoneTests: XCTestCase {

    private var csa: IPhoneKeyboardLayout!
    private var answersPath: String!

    override func setUpWithError() throws {
        csa = try XCTUnwrap(IPhoneKeyboardLayout.named("Canadian-CSA"), "Canadian-CSA missing on this Mac")
        answersPath = NSTemporaryDirectory() + "keyboard-layouts-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: answersPath)
    }

    private var both: KeyboardLayoutSet {
        KeyboardLayoutSet(layouts: [.init(name: "Canadian-CSA", layout: csa), .init(name: "US", layout: .usQWERTY)])
    }

    private func makeInput(phone: PhoneWithKeyboard, size: CGSize = CGSize(width: 410, height: 898),
                           answers: KeyboardLayoutAnswers) -> InputSimulation {
        let bridge = StubBridge()
        bridge.processRunning = false
        bridge.windowInfo = WindowInfo(windowID: 1, position: .zero, size: size, pid: 1)
        return InputSimulation(bridge: bridge, keyboardLayouts: both, layoutAnswers: answers,
                               pasteVerifier: PhoneFieldScreen(phone: phone),
                               keyPoster: phone, pasteboard: phone.pasteboard)
    }

    // MARK: - Which characters the layouts agree on

    func testLettersAgreeAndTheApostropheIsDisputed() {
        XCTAssertNotNil(both.keySequence(for: "a", chosen: nil))
        XCTAssertNil(both.keySequence(for: "'", chosen: nil), "CSA's apostrophe key types '<' on US")
        XCTAssertEqual(both.disputed(in: "J'arrive à l'école?"), ["'", "à", "é", "?"])
    }

    func testAGivenLayoutDecidesTheDisputedKeys() {
        XCTAssertEqual(both.keySequence(for: "'", chosen: .usQWERTY), IPhoneKeyboardLayout.usQWERTY.keySequence(for: "'"))
        XCTAssertEqual(both.keySequence(for: "'", chosen: csa), csa.keySequence(for: "'"))
    }

    func testOneLayoutDisputesNothing() {
        XCTAssertEqual(KeyboardLayoutSet(single: csa, name: "Canadian-CSA").disputed(in: "J'arrive"), [])
    }

    // MARK: - Typing on the iPhone 16 (US) with both layouts configured

    /// carnet#82, measured 2026-11-17: CSA keys on the iPhone 16 typed "J<arrive".
    func testWithoutAnAnswerTheApostropheIsPastedAndTheCallerIsTold() {
        let phone = PhoneWithKeyboard(layout: .usQWERTY)
        let input = makeInput(phone: phone, answers: KeyboardLayoutAnswers(path: answersPath))
        let result = input.typeText("J'arrive")
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(phone.fieldText, "J'arrive")
        XCTAssertEqual(phone.pasteboard.writes.first, "J'arrive", "the text is pasted in one run")
        XCTAssertTrue(result.notice?.contains("keyboard_layout") == true, result.notice ?? "nil")
    }

    func testTheRightAnswerTypesEveryCharacterByKey() {
        let phone = PhoneWithKeyboard(layout: .usQWERTY)
        let answers = KeyboardLayoutAnswers(path: answersPath)
        let input = makeInput(phone: phone, answers: answers)
        XCTAssertNil(input.rememberKeyboardLayout("us"))
        let result = input.typeText("J'arrive")
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(phone.fieldText, "J'arrive")
        XCTAssertTrue(phone.pasteboard.writes.isEmpty, "nothing pasted")
        XCTAssertNil(result.notice)
    }

    func testAWrongAnswerFailsTheCallAndIsForgotten() {
        let phone = PhoneWithKeyboard(layout: .usQWERTY)
        let answers = KeyboardLayoutAnswers(path: answersPath)
        let input = makeInput(phone: phone, answers: answers)
        XCTAssertNil(input.rememberKeyboardLayout("Canadian-CSA"))
        let result = input.typeText("J'arrive")
        XCTAssertFalse(result.success)
        XCTAssertEqual(phone.fieldText, "J<arrive")
        XCTAssertTrue(result.error?.contains("is forgotten") == true, result.error ?? "nil")
        XCTAssertNil(answers.answer(for: CGSize(width: 410, height: 898)))
    }

    /// The right answer with autocorrect rewriting a word: no evidence of a
    /// wrong layout, so the call succeeds with the usual notice and the
    /// answer is kept.
    func testAutocorrectUnderTheRightAnswerKeepsIt() {
        let phone = PhoneWithKeyboard(layout: .usQWERTY)
        phone.autocorrect = { $0.replacingOccurrences(of: "teh", with: "the") }
        let answers = KeyboardLayoutAnswers(path: answersPath)
        let input = makeInput(phone: phone, answers: answers)
        XCTAssertNil(input.rememberKeyboardLayout("US"))
        let result = input.typeText("teh l'adresse")
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(result.notice?.contains("autocorrect") == true, result.notice ?? "nil")
        XCTAssertEqual(answers.answer(for: CGSize(width: 410, height: 898)), "US")
    }

    func testTheMisreadingIsWhatTheOtherLayoutTypes() {
        XCTAssertEqual(both.misreadings(of: "J'arrive", chosen: csa), ["J<arrive"])
        XCTAssertEqual(both.misreadings(of: "bonjour", chosen: csa), [], "letters read the same")
    }

    func testAnswerGivenByAnotherProcessIsSeen() {
        let mine = KeyboardLayoutAnswers(path: answersPath)
        XCTAssertNil(mine.answer(for: CGSize(width: 410, height: 898)))
        KeyboardLayoutAnswers(path: answersPath).remember("US", for: CGSize(width: 410, height: 898))
        XCTAssertEqual(mine.answer(for: CGSize(width: 410, height: 898)), "US")
    }

    func testAnAnswerIsKeptPerPhoneAcrossRestarts() {
        let answers = KeyboardLayoutAnswers(path: answersPath)
        answers.remember("US", for: CGSize(width: 410, height: 898))
        answers.remember("Canadian-CSA", for: CGSize(width: 942, height: 430))
        let reloaded = KeyboardLayoutAnswers(path: answersPath)
        XCTAssertEqual(reloaded.answer(for: CGSize(width: 410, height: 898)), "US")
        XCTAssertEqual(reloaded.answer(for: CGSize(width: 430, height: 942)), "Canadian-CSA", "a rotation keeps it")
        XCTAssertNil(reloaded.answer(for: CGSize(width: 393, height: 852)), "another phone has no answer")
    }

    func testOnlyAConfiguredLayoutCanBeGiven() {
        let input = makeInput(phone: PhoneWithKeyboard(layout: .usQWERTY), answers: KeyboardLayoutAnswers(path: answersPath))
        let refusal = input.rememberKeyboardLayout("German")
        XCTAssertTrue(refusal?.contains("Canadian-CSA, US") == true, refusal ?? "nil")
    }
}

/// An iPhone whose hardware keyboard turns keystrokes into characters with
/// its own layout, as iPhone Mirroring's phones do; Cmd+V pastes the clipboard.
private final class PhoneWithKeyboard: KeyEventPosting, @unchecked Sendable {
    let pasteboard = RecordingPasteboard(contents: nil)
    private(set) var fieldText = ""
    private let layout: IPhoneKeyboardLayout
    /// What the iPhone does to the field after each key, as autocorrect does.
    var autocorrect: (String) -> String = { $0 }
    private let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'<>/?^éàè ")

    init(layout: IPhoneKeyboardLayout) { self.layout = layout }

    func postKey(keycode: UInt16, flags: CGEventFlags, targetPID: pid_t?) -> Bool {
        if flags.contains(.maskCommand), keycode == CGKeyMap.lookup("v")?.keycode {
            fieldText += pasteboard.contents ?? ""
        }
        return true
    }

    func postKeySequence(_ sequence: CGKeySequence, targetPID: pid_t?) -> Bool {
        guard let char = alphabet.first(where: { layout.keySequence(for: $0) == sequence }) else { return false }
        fieldText = autocorrect(fieldText + String(char))
        return true
    }
}

/// OCR of the phone: its text field.
private struct PhoneFieldScreen: ScreenDescribing, @unchecked Sendable {
    let phone: PhoneWithKeyboard

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
        ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: phone.fieldText, tapX: 200, tapY: 100, confidence: 0.95)],
            screenshotBase64: "")
    }
}
