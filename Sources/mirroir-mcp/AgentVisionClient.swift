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
