// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Uses AI vision (embacle) to suggest exploration actions when BFS hits a plateau.
// ABOUTME: Protocol abstraction allowing test doubles; concrete implementation queries embacle.

import Foundation
import HelperLib

/// Suggestion from the AI advisor for what to explore next.
struct ExplorationSuggestion: Sendable {
    /// The element text recommended for tapping.
    let elementText: String
    /// Reasoning for why this element was suggested.
    let reasoning: String
    /// Confidence score (0.0-1.0).
    let confidence: Double
}

/// Protocol for AI-guided exploration advice during plateau phases.
/// Abstracted for testability — production uses embacle, tests can inject stubs.
protocol ExplorationAdvising: Sendable {
    /// Given the current screen and exploration state, suggest elements to tap.
    ///
    /// - Parameters:
    ///   - screenshotBase64: Current screen screenshot for vision analysis.
    ///   - elements: OCR elements visible on the current screen.
    ///   - visitedElements: Elements already tapped on this screen.
    ///   - exploredScreenCount: Total screens discovered so far.
    /// - Returns: Ranked suggestions, or empty if the advisor cannot help.
    func suggest(
        screenshotBase64: String,
        elements: [TapPoint],
        visitedElements: Set<String>,
        exploredScreenCount: Int
    ) -> [ExplorationSuggestion]
}

/// Heuristic-based exploration advisor that scores untapped elements
/// by position, label characteristics, and context — no external API call.
/// Falls back to this when embacle is unavailable or in test environments.
struct HeuristicExplorationAdvisor: ExplorationAdvising {

    func suggest(
        screenshotBase64: String,
        elements: [TapPoint],
        visitedElements: Set<String>,
        exploredScreenCount: Int
    ) -> [ExplorationSuggestion] {
        let untapped = elements.filter { !visitedElements.contains($0.text) }
        guard !untapped.isEmpty else { return [] }

        return untapped
            .sorted { scoreElement($0) > scoreElement($1) }
            .prefix(3)
            .map { element in
                ExplorationSuggestion(
                    elementText: element.text,
                    reasoning: "Heuristic: untapped element at y=\(Int(element.tapY))",
                    confidence: 0.5
                )
            }
    }

    /// Score an element based on heuristics: mid-screen position, short label, etc.
    private func scoreElement(_ element: TapPoint) -> Double {
        var score: Double = 0
        // Mid-screen elements are more likely to be navigation targets
        if element.tapY > 200 && element.tapY < 700 { score += 2.0 }
        // Short labels are more likely to be tappable menu items
        if element.text.count <= 20 { score += 1.5 }
        // Very short labels might be icons or buttons
        if element.text.count <= 5 { score += 1.0 }
        return score
    }
}

/// Vision-based exploration advisor using embacle FFI for screen analysis.
/// Sends the current screenshot to embacle and asks it to identify the most
/// promising untapped element for discovering new screens.
struct VisionExplorationAdvisor: ExplorationAdvising {

    private static var timeoutSeconds: Int { EnvConfig.embacleTimeoutSeconds }

    func suggest(
        screenshotBase64: String,
        elements: [TapPoint],
        visitedElements: Set<String>,
        exploredScreenCount: Int
    ) -> [ExplorationSuggestion] {
        let untapped = elements.filter { !visitedElements.contains($0.text) }
        guard !untapped.isEmpty else { return [] }
        guard EmbacleFFI.isAvailable else {
            return HeuristicExplorationAdvisor().suggest(
                screenshotBase64: screenshotBase64, elements: elements,
                visitedElements: visitedElements, exploredScreenCount: exploredScreenCount
            )
        }

        let elementList = untapped.map { "\($0.text) at (\(Int($0.tapX)),\(Int($0.tapY)))" }
            .joined(separator: ", ")

        let prompt = "This is a screenshot of an iOS app during automated exploration. " +
            "\(exploredScreenCount) screens have been discovered so far. " +
            "These elements have NOT been tapped yet: \(elementList). " +
            "Which element is most likely to lead to a new, undiscovered screen? " +
            "Reply with ONLY the element text, nothing else."

        guard let responseText = sendVisionRequest(
            imageBase64: screenshotBase64, prompt: prompt
        ) else {
            return HeuristicExplorationAdvisor().suggest(
                screenshotBase64: screenshotBase64, elements: elements,
                visitedElements: visitedElements, exploredScreenCount: exploredScreenCount
            )
        }

        let trimmed = responseText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // Exact match against untapped element text
        if let match = untapped.first(where: { $0.text == trimmed }) {
            return [ExplorationSuggestion(
                elementText: match.text,
                reasoning: "Vision advisor recommended this element",
                confidence: 0.8
            )]
        }

        // Fuzzy match: check if the response contains an element text
        if let fuzzyMatch = untapped.first(where: {
            trimmed.localizedCaseInsensitiveContains($0.text) ||
            $0.text.localizedCaseInsensitiveContains(trimmed)
        }) {
            return [ExplorationSuggestion(
                elementText: fuzzyMatch.text,
                reasoning: "Vision advisor fuzzy match: \"\(trimmed)\"",
                confidence: 0.6
            )]
        }

        // Vision response didn't match any element — fall back to heuristic
        return HeuristicExplorationAdvisor().suggest(
            screenshotBase64: screenshotBase64, elements: elements,
            visitedElements: visitedElements, exploredScreenCount: exploredScreenCount
        )
    }

    /// Build an OpenAI-compatible vision request and send via embacle FFI.
    private func sendVisionRequest(imageBase64: String, prompt: String) -> String? {
        let userContent: [[String: Any]] = [
            ["type": "text", "text": prompt],
            ["type": "image_url", "image_url": [
                "url": "data:image/png;base64,\(imageBase64)",
            ]],
        ]

        let requestBody: [String: Any] = [
            "model": "copilot_headless",
            "max_tokens": 100,
            "messages": [
                ["role": "user", "content": userContent],
            ],
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        guard let responseData = EmbacleFFI.chatCompletion(
            requestJSON: body, timeoutSeconds: Self.timeoutSeconds
        ) else {
            return nil
        }

        // Extract text from OpenAI-format response
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return String(data: responseData, encoding: .utf8)
        }
        return content
    }
}
