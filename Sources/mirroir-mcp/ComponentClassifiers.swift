// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Classifier implementations bridging heuristic and LLM-based component detection.
// ABOUTME: LLM classification runs over MCP sampling or the configured agent, whichever is reachable.

import Foundation
import HelperLib

/// Supported component detection modes, controlled by MIRROIR_COMPONENT_DETECTION.
enum ComponentDetectionMode: String, Sendable {
    case heuristic
    case llmFirstScreen = "llm_first_screen"
    case llmEveryScreen = "llm_every_screen"
    case llmFallback = "llm_fallback"

    /// Build the appropriate component classifier for this detection mode.
    ///
    /// Two transports can reach a model, and the one chosen depends on what is
    /// actually available:
    ///
    /// - **Sampling** asks the client's own model. Nothing needs configuring on
    ///   this machine, so it is preferred whenever the client declares the
    ///   capability — that declaration is the client volunteering to serve these
    ///   requests.
    /// - **Agent** asks the model configured here, reaching every client
    ///   including those that cannot sample.
    ///
    /// With neither available there is no model to ask, and every mode
    /// classifies heuristically rather than building a classifier that cannot work.
    ///
    /// - Parameters:
    ///   - server: The MCP server, used to reach the client's model. Nil where
    ///     no server is in play, such as CLI invocations.
    ///   - agentConfig: The resolved AI agent, or nil when none is configured.
    func buildClassifier(
        server: MCPServer?, agentConfig: AgentConfig?
    ) -> any ComponentClassifying {
        let heuristic = HeuristicClassifier()
        let model: (() -> any ComponentClassifying)?
        if let server, server.clientSupportsSampling() {
            model = { SamplingClassifier(server: server) }
        } else if let agentConfig {
            model = { AgentClassifier(agentConfig: agentConfig) }
        } else {
            model = nil
        }
        guard let agent = model else { return heuristic }
        switch self {
        case .heuristic:
            return heuristic
        case .llmFirstScreen:
            return CompositeClassifier(
                primary: agent(), fallback: heuristic, primaryOnlyForFirstScreen: true)
        case .llmEveryScreen:
            return CompositeClassifier(
                primary: agent(), fallback: heuristic, primaryOnlyForFirstScreen: false)
        case .llmFallback:
            return CompositeClassifier(
                primary: heuristic, fallback: agent(), primaryOnlyForFirstScreen: false)
        }
    }
}

/// Wraps ComponentDetector.detect() as a ComponentClassifying implementation.
/// Used when only heuristic matching is needed (no LLM calls).
final class HeuristicClassifier: ComponentClassifying, @unchecked Sendable {
    init() {}

    func classify(
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition],
        screenHeight: Double
    ) -> [ScreenComponent]? {
        ComponentDetector.detect(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )
    }
}

/// Asks the MCP client's own model to classify screen components, over the
/// protocol's sampling capability.
///
/// Needs nothing configured on this machine — the model belongs to the client —
/// so it serves users who have no agent of their own. Only clients that declare
/// `sampling` are asked, and the `2026-07-28` revision routes such requests
/// through MRTR rather than a server-initiated write; `MCPServer` enforces both.
final class SamplingClassifier: ComponentClassifying, @unchecked Sendable {
    /// Ceiling for the classification reply; a full catalog answer runs well under this.
    private static let maxTokens = 2000

    private let server: MCPServer

    init(server: MCPServer) {
        self.server = server
    }

    func classify(
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition],
        screenHeight: Double
    ) -> [ScreenComponent]? {
        let prompt = ClassificationPrompt.build(classified: classified, definitions: definitions)

        let params = SamplingParams(
            messages: [SamplingMessage(role: "user", content: .text(prompt))],
            maxTokens: Self.maxTokens,
            systemPrompt: ClassificationPrompt.systemPrompt
        )

        guard let responseText = server.sendSamplingRequest(params) else {
            DebugLog.log("sampling", "Sampling request failed, falling back to heuristics")
            return nil
        }

        return ClassificationPrompt.parse(
            responseText,
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )
    }
}

/// Asks the configured AI agent to classify screen components, sending the OCR
/// elements and component catalog and parsing the structured JSON reply back
/// into ScreenComponents.
///
/// The agent is reached directly through the provider stack — the same path
/// `VisionScreenDescriber` and the exploration advisor use. It needs a model
/// configured on this machine, and in exchange works with every client,
/// including the many (Claude Code among them) that never declare `sampling`.
final class AgentClassifier: ComponentClassifying, @unchecked Sendable {
    /// Ceiling for the classification reply; a full catalog answer runs well under this.
    private static let maxTokens = 2000

    private let agentConfig: AgentConfig

    init(agentConfig: AgentConfig) {
        self.agentConfig = agentConfig
    }

    func classify(
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition],
        screenHeight: Double
    ) -> [ScreenComponent]? {
        let prompt = ClassificationPrompt.build(classified: classified, definitions: definitions)

        guard let responseText = requestChatCompletion(
            systemPrompt: ClassificationPrompt.systemPrompt,
            userText: prompt,
            model: agentConfig.model ?? defaultAgentModel,
            maxTokens: Self.maxTokens,
            agentConfig: agentConfig,
            transport: agentConfig.transport(),
            timeoutSeconds: EnvConfig.embacleTimeoutSeconds
        )?.text else {
            DebugLog.log("classifier", "Agent request failed, falling back to heuristics")
            return nil
        }

        return ClassificationPrompt.parse(
            responseText,
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )
    }
}

/// The classification question and the shape of its answer, shared by every
/// classifier that asks a model — so the prompt and the parser cannot drift
/// apart between the sampling and agent transports.
enum ClassificationPrompt {
    /// Instruction given to the model before the element listing.
    static let systemPrompt =
        "You analyze iOS app screens and classify OCR elements into UI components. "
        + "Respond ONLY with valid JSON, no markdown formatting."

    /// Build the prompt for the client LLM describing available components and current elements.
    static func build(
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition]
    ) -> String {
        var prompt = "Analyze the following OCR elements from an iOS app screen.\n"
        prompt += "Group them into UI components from the catalog below.\n\n"

        prompt += "## Component Catalog\n\n"
        for def in definitions {
            prompt += "- **\(def.name)**: \(def.description)"
            if def.interaction.clickable {
                prompt += " [clickable]"
            }
            prompt += "\n"
        }

        prompt += "\n## OCR Elements\n\n"
        for element in classified {
            prompt += "- \"\(element.point.text)\" at (\(Int(element.point.tapX)), "
            prompt += "\(Int(element.point.tapY))) role=\(element.role.rawValue)"
            if element.hasChevronContext {
                prompt += " [chevron]"
            }
            prompt += "\n"
        }

        prompt += "\n## Instructions\n\n"
        prompt += "Group the elements into components. For each group, specify:\n"
        prompt += "1. The component type from the catalog\n"
        prompt += "2. Which element texts belong to this component\n"
        prompt += "3. Which element to tap (if clickable)\n\n"
        prompt += "Respond with a JSON array:\n"
        prompt += """
            [
              {"component": "table-row-disclosure", "elements": ["General", ">"], "tap_target": "General"},
              {"component": "explanation-text", "elements": ["Some help text"], "tap_target": null}
            ]
            """

        return prompt
    }

    /// Parse the LLM's JSON response into ScreenComponents.
    /// Falls back to nil if the response is not valid JSON.
    static func parse(
        _ responseText: String,
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition],
        screenHeight: Double
    ) -> [ScreenComponent]? {
        // Strip markdown code fences if present
        var text = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json") {
            text = String(text.dropFirst(7))
        } else if text.hasPrefix("```") {
            text = String(text.dropFirst(3))
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = text.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            DebugLog.log("sampling", "Failed to parse sampling response as JSON array")
            return nil
        }

        let defsByName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
        let classifiedByText = Dictionary(
            classified.map { ($0.point.text, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var components: [ScreenComponent] = []
        for entry in jsonArray {
            guard let componentName = entry["component"] as? String,
                  let elementTexts = entry["elements"] as? [String],
                  let definition = defsByName[componentName] else {
                continue
            }

            let matchedElements = elementTexts.compactMap { classifiedByText[$0] }
            guard !matchedElements.isEmpty else { continue }

            let tapTargetText = entry["tap_target"] as? String
            let tapTarget = tapTargetText.flatMap { text in
                matchedElements.first { $0.point.text == text }?.point
            }

            let ys = matchedElements.map { $0.point.tapY }
            let hasChevron = matchedElements.contains { element in
                ElementClassifier.chevronCharacters.contains(
                    element.point.text.trimmingCharacters(in: .whitespaces)
                )
            }

            components.append(ScreenComponent(
                kind: componentName,
                definition: definition,
                elements: matchedElements,
                tapTarget: tapTarget,
                hasChevron: hasChevron,
                topY: ys.min() ?? 0,
                bottomY: ys.max() ?? 0
            ))
        }

        return components.isEmpty ? nil : components
    }
}

/// Combines a primary and fallback classifier with configurable strategy.
/// When `primaryOnlyForFirstScreen` is true, the primary classifier is used only for
/// the first screen, and the fallback handles all subsequent screens.
final class CompositeClassifier: ComponentClassifying, @unchecked Sendable {
    /// The classifier consulted first. Readable so callers and tests can see
    /// which transport was selected without invoking a model.
    let primary: ComponentClassifying
    let fallback: ComponentClassifying
    private let primaryOnlyForFirstScreen: Bool
    private var screensSeen: Int = 0
    private let lock = NSLock()

    init(
        primary: ComponentClassifying,
        fallback: ComponentClassifying,
        primaryOnlyForFirstScreen: Bool
    ) {
        self.primary = primary
        self.fallback = fallback
        self.primaryOnlyForFirstScreen = primaryOnlyForFirstScreen
    }

    func classify(
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition],
        screenHeight: Double
    ) -> [ScreenComponent]? {
        lock.lock()
        let currentScreen = screensSeen
        screensSeen += 1
        lock.unlock()

        let usePrimary = !primaryOnlyForFirstScreen || currentScreen == 0

        if usePrimary {
            if let result = primary.classify(
                classified: classified, definitions: definitions,
                screenHeight: screenHeight
            ) {
                return result
            }
        }

        return fallback.classify(
            classified: classified, definitions: definitions,
            screenHeight: screenHeight
        )
    }
}
