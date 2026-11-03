// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The one builder of OpenAI-compatible /v1/chat/completions requests: prompts, an optional image, one reply.
// ABOUTME: The screen describer, the exploration advisor, the component classifier and scene play all send through it.

import Foundation

/// Sends one chat-completion request (transport, url, headers, body, timeout seconds)
/// and returns the response body, or nil on failure. The seam tests replace.
typealias AgentRequestSending = @Sendable (AgentTransport, URL, [String: String], Data, Int) -> Data?

/// The production sender: `sendAgentRequest` over the given transport.
let liveAgentRequestSender: AgentRequestSending = {
    sendAgentRequest(transport: $0, url: $1, headers: $2, body: $3, timeoutSeconds: $4)
}

/// What one chat completion answered.
struct ChatCompletionReply: Sendable, Equatable {
    /// The assistant message's text.
    let text: String
    /// Token counts, when the provider reported them.
    let usage: ChatCompletionUsage?
    /// The model the provider said answered, when it said.
    let responseModel: String?
}

/// A PNG sent with a request, and the text placed before it in the user turn.
struct ChatCompletionImage: Sendable {
    let pngBase64: String
    let caption: String
}

/// Ask `model` one question, with an optional image, and return its reply.
///
/// The request is the OpenAI-compatible `/v1/chat/completions` shape every
/// provider speaks: an optional system turn, then a user turn holding the text,
/// or the caption and the image as a data URL. It travels over `transport`;
/// the agent's `apiKeyEnvVar`, when set in the environment, becomes a bearer token.
///
/// - Returns: The reply, or nil when the agent is unreachable or answers in a
///   shape with no message content.
func requestChatCompletion(
    systemPrompt: String?,
    userText: String,
    image: ChatCompletionImage? = nil,
    model: String,
    maxTokens: Int,
    agentConfig: AgentConfig,
    transport: AgentTransport,
    timeoutSeconds: Int,
    send: AgentRequestSending = liveAgentRequestSender
) -> ChatCompletionReply? {
    let baseURL = agentConfig.baseURL ?? defaultAgentBaseURL
    guard let url = URL(string: baseURL + "/v1/chat/completions") else { return nil }

    let userContent: Any
    if let image {
        userContent = [
            ["type": "text", "text": image.caption + userText],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(image.pngBase64)"]],
        ] as [[String: Any]]
    } else {
        userContent = userText
    }
    var messages: [[String: Any]] = []
    if let systemPrompt {
        messages.append(["role": "system", "content": systemPrompt])
    }
    messages.append(["role": "user", "content": userContent])
    let requestBody: [String: Any] = [
        "model": model,
        "max_tokens": maxTokens,
        "messages": messages,
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }

    var headers = ["Content-Type": "application/json"]
    if let apiKeyEnv = agentConfig.apiKeyEnvVar,
       let apiKey = ProcessInfo.processInfo.environment[apiKeyEnv],
       !apiKey.isEmpty {
        headers["Authorization"] = "Bearer \(apiKey)"
    }

    guard let responseData = send(transport, url, headers, body, timeoutSeconds),
          let text = extractChatCompletionText(from: responseData) else { return nil }
    let responseModel = (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])?
        .flatMap { $0["model"] as? String }
    return ChatCompletionReply(
        text: text, usage: ChatCompletionUsage.parse(from: responseData),
        responseModel: responseModel)
}
