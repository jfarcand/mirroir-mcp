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
// ABOUTME: System-boundary protocols for services outside the Mac's own APIs: a vision model, a scene's move picker,
// ABOUTME: the HTTP listener. Window, input and capture boundaries have their own *Protocols.swift files.

import Foundation

// MARK: - Vision Completion

/// A vision model a `scene:` step asks to pick one control per frame.
/// The system boundary is a paid, non-deterministic model call; tests stand it in.
protocol VisionCompleting: Sendable {
    /// The model requests are sent to: a scene's drift key, so runs are compared
    /// only with runs of the same model.
    var model: String { get }

    /// Ask about one frame and return the reply, or nil when the model gave none
    /// within `timeoutSeconds`.
    func complete(
        systemPrompt: String, image: ChatCompletionImage, timeoutSeconds: Int
    ) -> ChatCompletionReply?
}

// MARK: - Scene Move Picker

/// What a scene's external move picker answered for one frame.
enum SceneDecisionOutcome: Equatable, Sendable {
    /// It exited 0; its stdout, to be read as one action.
    case answered(String)
    /// It could not start or exited non-zero; why, for the evidence.
    case failed(String)
    /// It ran past its time and was stopped.
    case timedOut
}

/// The external move picker a scenario names for a `decider: required` scene.
/// The system boundary is a user-supplied program; tests stand it in.
protocol SceneDeciding: Sendable {
    /// The command as the scenario wrote it, for the evidence.
    var command: String { get }

    /// Send `input` (one JSON object) and wait at most `timeoutSeconds` for its answer.
    func decide(input: Data, timeoutSeconds: Int) -> SceneDecisionOutcome
}

/// A listener that hands each HTTP request to a responder; `start` throws `HTTPServerError`.
protocol HTTPServing: Sendable {
    func start(responder: HTTPResponder) throws
    var boundPort: UInt16? { get }
    func stop()
}

/// The connection a request arrived on, as the responder sees it while it
/// works: whether the client is still there, and a way to stream events to it.
protocol HTTPExchangeChannel: AnyObject, Sendable {
    /// Whether the client has closed its connection.
    var isAbandoned: Bool { get }
    /// Run `hook` when the client closes its connection, or at once if it has.
    func onAbandon(_ hook: @escaping @Sendable () -> Void)
    /// Send one server-sent event carrying `json`. The first event turns the
    /// reply into a `text/event-stream`; the responder then ends it with
    /// `HTTPReply.streamEnded`.
    func sendEvent(_ json: Data)
}
