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
// ABOUTME: Tests the classify_screen multi round-trip exchange end to end.
// ABOUTME: Covers the question asked, the state carried, and the answer resumed.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ScreenClassificationTests: XCTestCase {

    private let definitions = ComponentCatalog.definitions

    private func screen() -> ScreenClassification.CapturedScreen {
        ScreenClassification.CapturedScreen(
            elements: [
                TapPoint(text: "General", tapX: 100, tapY: 400, confidence: 0.95),
                TapPoint(text: "Privacy", tapX: 100, tapY: 460, confidence: 0.93),
            ],
            screenHeight: 890
        )
    }

    // MARK: - The question

    func testAskClientRequestsSamplingWithTheClassificationPrompt() {
        let result = ScreenClassification.askClient(
            screen(), definitions: definitions, maxTokens: 2000)

        XCTAssertFalse(result.isError)
        guard let request = result.inputRequests[ScreenClassification.requestKey] else {
            return XCTFail("expected a classification request")
        }
        XCTAssertEqual(request.method, "sampling/createMessage")
        XCTAssertEqual(
            request.params.member("systemPrompt")?.asString(),
            ClassificationPrompt.systemPrompt)

        guard case .array(let messages)? = request.params.member("messages"),
              let text = messages.first?.member("content")?.member("text")?.asString() else {
            return XCTFail("expected a user message carrying the prompt")
        }
        XCTAssertTrue(text.contains("General"), "the prompt names the screen's elements")
        XCTAssertNotNil(result.requestState, "the screen must be carried to the retry")
    }

    // MARK: - The resume

    /// The retry classifies the screen as it was when asked, not as it is now —
    /// the device may have moved on while the client was answering.
    func testResumeRecoversTheScreenThatWasAskedAbout() {
        let result = ScreenClassification.askClient(
            screen(), definitions: definitions, maxTokens: 2000)
        guard let state = result.requestState else { return XCTFail("no state issued") }

        let context = MCPToolCallContext(inputResponses: [:], requestState: state)
        guard let resumed = ScreenClassification.resumeScreen(from: context) else {
            return XCTFail("state must decode on the retry")
        }
        XCTAssertEqual(resumed.screenHeight, 890)
        XCTAssertEqual(resumed.elements.map(\.text), ["General", "Privacy"])
        XCTAssertEqual(resumed.elements.first?.tapY, 400)
    }

    func testResumeRejectsTamperedState() {
        let result = ScreenClassification.askClient(
            screen(), definitions: definitions, maxTokens: 2000)
        guard let state = result.requestState else { return XCTFail("no state issued") }
        let forged = String(state.reversed())

        let context = MCPToolCallContext(inputResponses: [:], requestState: forged)
        XCTAssertNil(ScreenClassification.resumeScreen(from: context),
            "state edited by the client must not resume")
    }

    func testResumeWithoutStateReturnsNil() {
        XCTAssertNil(ScreenClassification.resumeScreen(from: MCPToolCallContext()))
    }

    // MARK: - The answer

    func testReplyTextReadsTheClientsSamplingResult() {
        let context = MCPToolCallContext(
            inputResponses: [
                ScreenClassification.requestKey: .object([
                    "role": .string("assistant"),
                    "model": .string("some-model"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("[]"),
                    ]),
                ]),
            ],
            requestState: nil)

        XCTAssertEqual(ScreenClassification.replyText(from: context), "[]")
    }

    func testReplyTextNilWhenClientAnsweredSomethingElse() {
        let context = MCPToolCallContext(
            inputResponses: ["unrelated": .object(["content": .object([:])])],
            requestState: nil)
        XCTAssertNil(ScreenClassification.replyText(from: context))
    }

    func testFirstAttemptHasNoReply() {
        XCTAssertNil(ScreenClassification.replyText(from: MCPToolCallContext()))
    }

    // MARK: - Report

    func testReportListsComponentsAndTheirElements() {
        let classified = ElementClassifier.classify(screen().elements, screenHeight: 890)
        let components = ComponentDetector.detect(
            classified: classified, definitions: definitions, screenHeight: 890)
        guard !components.isEmpty else {
            return XCTFail("expected the sample screen to yield components")
        }

        let report = ScreenClassificationReport.format(
            components: components, elementCount: 2)
        XCTAssertTrue(report.contains("=== Screen Classification ==="))
        XCTAssertTrue(report.contains("2 OCR elements"))
        XCTAssertTrue(report.contains(components[0].definition.name))
    }

    func testReportSaysSoWhenNothingMatched() {
        let report = ScreenClassificationReport.format(components: [], elementCount: 7)
        XCTAssertTrue(report.contains("No components matched"))
        XCTAssertTrue(report.contains("7 OCR elements"))
    }
}
