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
// ABOUTME: Classifies the current screen's OCR elements into components using a model.
// ABOUTME: Round-trips through the client via MRTR when the model belongs to the client.

import Foundation
import HelperLib

/// Classifies one screen into components, asking a model and, where the model
/// belongs to the client, doing so across a multi round-trip exchange.
///
/// Single-screen by design. The classification is asked once, so the request can
/// end and be retried with the answer — which is what the `2026-07-28` revision
/// requires of any server-to-client request, and what a long device-driving
/// operation cannot offer.
enum ScreenClassification {
    /// Identifier for the classification request inside `inputRequests`. Stable,
    /// since the answer comes back keyed by it.
    static let requestKey = "classify_screen"

    /// Method this exchange issues state for; state from any other is rejected.
    static let stateMethod = "tools/call"

    /// Elements carried across the round trip so the retry classifies the screen
    /// as it was when the question was asked, not as it is when the answer lands.
    struct CapturedScreen: Sendable {
        let elements: [TapPoint]
        let screenHeight: Double
    }

    /// Build the `input_required` result asking the client's model to classify
    /// `screen`, carrying the screen forward in signed state.
    static func askClient(
        _ screen: CapturedScreen, definitions: [ComponentDefinition], maxTokens: Int
    ) -> MCPToolResult {
        let classified = ElementClassifier.classify(
            screen.elements, screenHeight: screen.screenHeight)
        let prompt = ClassificationPrompt.build(classified: classified, definitions: definitions)

        let params: JSONValue = .object([
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .object(["type": .string("text"), "text": .string(prompt)]),
                ]),
            ]),
            "systemPrompt": .string(ClassificationPrompt.systemPrompt),
            "maxTokens": .number(Double(maxTokens)),
        ])

        guard let state = RequestStateCodec.encode(
            encodeScreen(screen), method: stateMethod
        ) else {
            return .error("Could not encode the screen for a follow-up request")
        }

        return .inputRequired(
            [requestKey: MCPInputRequest(method: "sampling/createMessage", params: params)],
            requestState: state)
    }

    /// Recover the screen a previous `askClient` asked about.
    ///
    /// Returns nil when the state is absent, forged, expired, or issued for
    /// another method — every case meaning the exchange cannot be resumed and
    /// the question must be asked again.
    static func resumeScreen(from context: MCPToolCallContext) -> CapturedScreen? {
        guard let state = context.requestState,
              let payload = RequestStateCodec.decode(state, method: stateMethod) else {
            return nil
        }
        return decodeScreen(payload)
    }

    /// The model's reply text from the client's answer, if it supplied one.
    static func replyText(from context: MCPToolCallContext) -> String? {
        guard let answer = context.inputResponses[requestKey] else { return nil }
        // CreateMessageResult carries a single content block.
        if let text = answer.member("content")?.member("text")?.asString() {
            return text
        }
        return nil
    }

    /// Turn a model reply into components for the screen it was asked about.
    static func components(
        fromReply reply: String, screen: CapturedScreen, definitions: [ComponentDefinition]
    ) -> [ScreenComponent]? {
        let classified = ElementClassifier.classify(
            screen.elements, screenHeight: screen.screenHeight)
        return ClassificationPrompt.parse(
            reply, classified: classified,
            definitions: definitions, screenHeight: screen.screenHeight)
    }

    // MARK: - State payload

    private static func encodeScreen(_ screen: CapturedScreen) -> [String: JSONValue] {
        [
            "screenHeight": .number(screen.screenHeight),
            "elements": .array(screen.elements.map { element in
                .object([
                    "text": .string(element.text),
                    "x": .number(element.tapX),
                    "y": .number(element.tapY),
                    "confidence": .number(Double(element.confidence)),
                ])
            }),
        ]
    }

    private static func decodeScreen(_ payload: [String: JSONValue]) -> CapturedScreen? {
        guard let screenHeight = payload["screenHeight"]?.asNumber(),
              case .array(let raw)? = payload["elements"] else { return nil }
        let elements = raw.compactMap { entry -> TapPoint? in
            guard let text = entry.member("text")?.asString(),
                  let x = entry.member("x")?.asNumber(),
                  let y = entry.member("y")?.asNumber() else { return nil }
            return TapPoint(
                text: text, tapX: x, tapY: y,
                confidence: Float(entry.member("confidence")?.asNumber() ?? 1.0))
        }
        return CapturedScreen(elements: elements, screenHeight: screenHeight)
    }
}
