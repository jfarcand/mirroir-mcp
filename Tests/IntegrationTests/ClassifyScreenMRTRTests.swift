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
// ABOUTME: Drives the classify_screen multi round-trip exchange against FakeMirroring.
// ABOUTME: Asks, answers as the client would, and checks the retry returns real components.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Exercises the `2026-07-28` input exchange over a real screen: the tool asks
/// the client's model to classify it, the client answers, and the retry
/// completes the call.
///
/// Unit tests cover each step in isolation; this one proves the steps fit
/// together over a screen that was actually captured, with the elements the OCR
/// pipeline really produced.
final class ClassifyScreenMRTRTests: XCTestCase {

    private var bridge: MirroringBridge!
    private var describer: ScreenDescriber!
    private var capture: ScreenCapture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try IntegrationTestHelper.ensureFakeMirroringRunning()
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw IntegrationTestError.windowNotCapturable
        }
        capture = ScreenCapture(bridge: bridge)
        describer = ScreenDescriber(bridge: bridge, capture: capture)

        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
        usleep(1_000_000)
    }

    override func tearDown() {
        bridge = nil
        describer = nil
        capture = nil
        super.tearDown()
    }

    /// Capture the live screen the way the tool does.
    private func liveScreen() throws -> ScreenClassification.CapturedScreen {
        guard let described = describer.describe() else {
            throw IntegrationTestError.windowNotCapturable
        }
        guard let size = bridge.getWindowInfo()?.size else {
            throw IntegrationTestError.windowNotCapturable
        }
        XCTAssertFalse(described.elements.isEmpty, "FakeMirroring should render elements")
        return ScreenClassification.CapturedScreen(
            elements: described.elements, screenHeight: size.height)
    }

    /// The whole exchange: ask about a real screen, answer as a client would,
    /// and confirm the retry classifies the screen that was asked about.
    func testRoundTripClassifiesTheCapturedScreen() throws {
        let definitions = ComponentCatalog.definitions
        let screen = try liveScreen()

        // 1. The tool asks.
        let asked = ScreenClassification.askClient(
            screen, definitions: definitions, maxTokens: 2000)
        guard let request = asked.inputRequests[ScreenClassification.requestKey],
              let state = asked.requestState else {
            return XCTFail("expected a classification request carrying state")
        }
        XCTAssertEqual(request.method, "sampling/createMessage")

        // The prompt must name elements really present on the captured screen.
        guard case .array(let messages)? = request.params.member("messages"),
              let prompt = messages.first?.member("content")?.member("text")?.asString() else {
            return XCTFail("expected a prompt")
        }
        let anyElement = screen.elements.first?.text ?? ""
        XCTAssertTrue(prompt.contains(anyElement),
            "the prompt should describe the screen that was captured")

        // 2. The client answers. A model would return JSON naming components and
        //    their elements; this stands in for that reply.
        let reply = modelReply(for: screen, definitions: definitions)
        let context = MCPToolCallContext(
            inputResponses: [
                ScreenClassification.requestKey: .object([
                    "role": .string("assistant"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(reply),
                    ]),
                ]),
            ],
            requestState: state)

        // 3. The retry resumes the captured screen and completes.
        guard let resumed = ScreenClassification.resumeScreen(from: context) else {
            return XCTFail("the state issued in step 1 must resume")
        }
        XCTAssertEqual(resumed.elements.count, screen.elements.count,
            "the retry classifies the screen that was asked about")
        XCTAssertEqual(resumed.elements.first?.text, screen.elements.first?.text)

        guard let replyText = ScreenClassification.replyText(from: context) else {
            return XCTFail("the client's answer must be readable")
        }
        let components = ScreenClassification.components(
            fromReply: replyText, screen: resumed, definitions: definitions)
        XCTAssertNotNil(components, "the model's reply must yield components")

        let report = ScreenClassificationReport.format(
            components: components ?? [], elementCount: resumed.elements.count)
        XCTAssertTrue(report.contains("=== Screen Classification ==="))
    }

    /// State issued for one screen must not be usable once altered, even with a
    /// real capture behind it.
    func testAlteredStateIsRefusedOnRetry() throws {
        let screen = try liveScreen()
        let asked = ScreenClassification.askClient(
            screen, definitions: ComponentCatalog.definitions, maxTokens: 2000)
        guard let state = asked.requestState else { return XCTFail("no state issued") }

        let tampered = MCPToolCallContext(
            inputResponses: [:], requestState: String(state.dropLast()) + "X")
        XCTAssertNil(ScreenClassification.resumeScreen(from: tampered))
    }

    /// Build a reply in the shape the classification prompt asks for, naming
    /// components the catalog defines and elements the screen actually has.
    private func modelReply(
        for screen: ScreenClassification.CapturedScreen,
        definitions: [ComponentDefinition]
    ) -> String {
        guard let definition = definitions.first,
              let element = screen.elements.first else {
            return "[]"
        }
        return """
            [{"component": "\(definition.name)", "elements": ["\(element.text)"]}]
            """
    }
}
