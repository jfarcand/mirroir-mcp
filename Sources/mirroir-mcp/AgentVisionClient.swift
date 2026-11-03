// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The VisionCompleting a scene plays with: one chat completion with the frame, through the configured scene agent.
// ABOUTME: Sends through requestChatCompletion, the single request builder, over the agent's own transport.

import Foundation
import HelperLib

/// Asks an agent about one frame through `requestChatCompletion`.
struct AgentVisionClient: VisionCompleting {
    let agentConfig: AgentConfig
    let send: AgentRequestSending

    init(agentConfig: AgentConfig, send: @escaping AgentRequestSending = liveAgentRequestSender) {
        self.agentConfig = agentConfig
        self.send = send
    }

    var model: String { agentConfig.model ?? defaultAgentModel }

    /// The client for the configured scene agent (`sceneAgent`), or nil when
    /// that name resolves to no agent.
    static func configured(name: String = EnvConfig.sceneAgent) -> AgentVisionClient? {
        AIAgentRegistry.resolve(name: name).map { AgentVisionClient(agentConfig: $0) }
    }

    func complete(
        systemPrompt: String, image: ChatCompletionImage, timeoutSeconds: Int
    ) -> ChatCompletionReply? {
        requestChatCompletion(
            systemPrompt: systemPrompt,
            userText: "",
            image: image,
            model: model,
            maxTokens: agentConfig.maxTokens,
            agentConfig: agentConfig,
            transport: agentConfig.transport(),
            timeoutSeconds: timeoutSeconds,
            send: send)
    }
}
