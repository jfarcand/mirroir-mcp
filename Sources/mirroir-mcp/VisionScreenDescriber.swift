// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: AI vision-based screen describer using embacle or compatible vision API.
// ABOUTME: Implements ScreenDescribing by sending screenshots to a vision model instead of local OCR.

import CoreGraphics
import Foundation
import HelperLib
import ImageIO

/// Screen describer that uses an AI vision model to identify UI elements.
/// Captures a screenshot, resizes it for the vision API, sends it with a system prompt,
/// and parses the response into TapPoints in window-point space.
final class VisionScreenDescriber: @unchecked Sendable {
    private let bridge: any WindowBridging
    private let capture: any ScreenCapturing
    private let agentConfig: AgentConfig
    private let targetImageWidth: Int

    init(
        bridge: any WindowBridging,
        capture: any ScreenCapturing,
        agentConfig: AgentConfig,
        targetImageWidth: Int = EnvConfig.visionImageWidth
    ) {
        self.bridge = bridge
        self.capture = capture
        self.agentConfig = agentConfig
        self.targetImageWidth = targetImageWidth
    }

    func describe() -> ScreenDescriber.DescribeResult? {
        guard let info = bridge.getWindowInfo(), info.windowID != 0 else { return nil }
        guard let data = capture.captureData() else { return nil }

        // Resize for the vision API (Retina PNGs are too large)
        guard let resized = ImageResizer.resize(
            pngData: data, targetWidth: targetImageWidth, windowSize: info.size
        ) else {
            DebugLog.log("vision", "describe: image resize failed")
            return nil
        }

        let visionStart = CFAbsoluteTimeGetCurrent()

        // Send to vision model and parse response
        guard let responseText = sendVisionRequest(imageBase64: resized.base64) else {
            DebugLog.log("vision", "describe: vision API request failed")
            return nil
        }

        let visionMs = Int((CFAbsoluteTimeGetCurrent() - visionStart) * 1000)
        DebugLog.log("vision", "describe: response received in \(visionMs)ms")

        // Parse response and scale coordinates to window points
        let (elements, hints) = VisionResponseParser.parse(
            responseText: responseText,
            scaleX: resized.scaleX,
            scaleY: resized.scaleY
        )

        DebugLog.log("vision", "describe: \(elements.count) elements, \(hints.count) hints, " +
            "scale=(\(String(format: "%.2f", resized.scaleX)),\(String(format: "%.2f", resized.scaleY))) " +
            "time=\(visionMs)ms")

        // Grid overlay on the original (full-resolution) screenshot for the MCP client
        let griddedData = GridOverlay.addOverlay(to: data, windowSize: info.size) ?? data
        let base64 = griddedData.base64EncodedString()

        return ScreenDescriber.DescribeResult(
            elements: elements, hints: hints,
            screenshotBase64: base64, ocrTimeMs: visionMs
        )
    }

    // MARK: - Vision API Request

    /// Send the screenshot to the configured vision model and return the response text.
    private func sendVisionRequest(imageBase64: String) -> String? {
        let baseURL = agentConfig.baseURL ?? "http://localhost:3000"
        guard let url = URL(string: baseURL + "/v1/chat/completions") else { return nil }

        let systemPrompt = loadDiagnosisPrompt(filename: "screen-describe.md")

        // Build multipart content with image for OpenAI-compatible vision API.
        // This format works with embacle (copilot_headless), OpenAI, and compatible providers.
        let userContent: [[String: Any]] = [
            ["type": "text", "text": "Return a JSON array of all tappable UI elements in this screenshot. ONLY output the JSON array, nothing else."],
            ["type": "image_url", "image_url": [
                "url": "data:image/png;base64,\(imageBase64)",
            ]],
        ]

        // Use copilot_headless for vision (supports image payloads)
        let modelName = resolveVisionModel()

        let requestBody: [String: Any] = [
            "model": modelName,
            "max_tokens": agentConfig.maxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        var headers = ["Content-Type": "application/json"]

        // Support optional auth
        if let apiKeyEnv = agentConfig.apiKeyEnvVar,
           let apiKey = ProcessInfo.processInfo.environment[apiKeyEnv],
           !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }

        guard let responseData = sendAgentHTTPRequest(
            url: url, headers: headers, body: body,
            timeoutSeconds: EnvConfig.embacleTimeoutSeconds
        ) else {
            return nil
        }

        return extractResponseText(from: responseData)
    }

    /// Extract text content from an OpenAI-compatible chat completions response.
    private func extractResponseText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            return String(data: data, encoding: .utf8)
        }
        return content
    }

    /// Resolve the vision-capable model name.
    /// For embacle, vision requires the `copilot_headless` provider prefix.
    private func resolveVisionModel() -> String {
        if agentConfig.provider == .embacle {
            return "copilot_headless"
        }
        return agentConfig.model ?? "copilot_headless"
    }
}
