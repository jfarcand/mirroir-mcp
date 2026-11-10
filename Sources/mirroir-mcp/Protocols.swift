// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
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
