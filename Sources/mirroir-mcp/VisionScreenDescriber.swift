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
    /// Built-in vision system prompt, used when no `screen-describe.md` override exists in the
    /// prompt directories. Its keys mirror `VisionResponseParser.VisionElement`: label/x/y/type.
    static let defaultSystemPrompt = """
        You are a UI element detector for iPhone automation. Respond with a raw JSON array and nothing else: no prose, no markdown fences.

        Each element has four fields:
        - "label": visible text exactly as shown on screen (use "label", not "name" or "title")
        - "x": center X coordinate as an integer, in pixels relative to the image
        - "y": center Y coordinate as an integer, in pixels relative to the image
        - "type": one of "app", "button", "tab", "card", "link", "icon", "back_button", "search_bar", "toggle", "text_field", "nav_title"

        `x` and `y` are integers at the top level of each object, not inside a "center" or "position" object; an element without them cannot be tapped.

        Example response format:
        [{"label": "Settings", "x": 200, "y": 150, "type": "app"}, {"label": "Search", "x": 350, "y": 840, "type": "button"}]

        Include every tappable element. For cards with data values, combine title and value (e.g. "Activité — 1 030 cal"). For back chevrons, use type "back_button".
        """

    /// Sends one chat-completion request (transport, url, headers, body, timeout seconds)
    /// and returns the response body, or nil on failure.
    typealias AgentRequestSending = @Sendable (AgentTransport, URL, [String: String], Data, Int) -> Data?

    private let bridge: any WindowBridging
    private let capture: any ScreenCapturing
    /// Local OCR/icon pass that confirms a near-uniform frame is really empty
    /// before the paid vision call is skipped.
    private let localDescriber: ScreenDescriber
    private let agentConfig: AgentConfig
    private let targetImageWidth: Int
    private let sendRequest: AgentRequestSending

    init(
        bridge: any WindowBridging,
        capture: any ScreenCapturing,
        localDescriber: ScreenDescriber,
        agentConfig: AgentConfig,
        targetImageWidth: Int = EnvConfig.visionImageWidth,
        sendRequest: @escaping AgentRequestSending = {
            sendAgentRequest(transport: $0, url: $1, headers: $2, body: $3, timeoutSeconds: $4)
        }
    ) {
        self.bridge = bridge
        self.capture = capture
        self.localDescriber = localDescriber
        self.agentConfig = agentConfig
        self.targetImageWidth = targetImageWidth
        self.sendRequest = sendRequest
    }

    /// Describe the screen with the vision model.
    ///
    /// Nil `settleTimeoutUs` waits up to `frameSettleTimeoutUs` for a settled
    /// frame, like the screenshot tool: a frame taken mid-transition (e.g. right
    /// after a rotation) is stale or blank, and the vision call is billed in full
    /// either way. Callers on a constantly animated screen (a game scene) pass 0.
    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
        guard let result = capture.captureSettledWithInfo(
            timeoutUs: settleTimeoutUs ?? EnvConfig.frameSettleTimeoutUs
        ) else { return nil }
        let info = result.info
        var data = result.data

        // A uniform frame has nothing to describe: report the transition
        // instead of paying the model to answer "blank screen". The pixel test
        // alone cannot tell a black mid-rotation frame from a dark splash with
        // one short label ("Tap to play", "Loading..."), so the local OCR/icon
        // pass on the same frame must also come back empty before the call is skipped.
        if BlankFrameDetector.isBlank(pngData: data),
           let local = localDescriber.describe(frame: result), local.screenBlank {
            DebugLog.log("vision", "describe: blank frame confirmed by local OCR, vision call skipped")
            return local
        }

        // In Larger zoom mode, the screenshot has dark borders around the
        // iOS content. Crop them before sending to the vision model so it
        // only sees actual UI elements, not black bars.
        if let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
            let contentBounds = ContentBoundsDetector.detect(image: image)
            let widthMargin = Double(image.width) * 0.05
            let heightMargin = Double(image.height) * 0.05
            let hasBorders = Double(contentBounds.width) < Double(image.width) - widthMargin
                && Double(contentBounds.height) < Double(image.height) - heightMargin
            if hasBorders,
               let cropped = image.cropping(to: CGRect(
                   x: Int(contentBounds.minX), y: Int(contentBounds.minY),
                   width: Int(contentBounds.width), height: Int(contentBounds.height)
               )) {
                DebugLog.log("vision", "Larger mode detected — cropping borders before resize")
                let mutableData = NSMutableData()
                if let dest = CGImageDestinationCreateWithData(
                    mutableData as CFMutableData, "public.png" as CFString, 1, nil
                ) {
                    CGImageDestinationAddImage(dest, cropped, nil)
                    if CGImageDestinationFinalize(dest) {
                        data = mutableData as Data
                    }
                }
            }
        }

        // Resize for the vision API (Retina PNGs are too large)
        guard let resized = ImageResizer.resize(
            pngData: data, targetWidth: targetImageWidth, windowSize: info.size
        ) else {
            DebugLog.log("vision", "describe: image resize failed")
            return nil
        }

        let visionStart = CFAbsoluteTimeGetCurrent()

        // Send to vision model with resized image dimensions so the model
        // knows the exact coordinate space to use for x/y values.
        guard let response = sendVisionRequest(
            imageBase64: resized.base64,
            imageWidth: resized.width,
            imageHeight: resized.height
        ) else {
            DebugLog.log("vision", "describe: vision API request failed")
            return nil
        }
        let responseText = response.text

        let visionMs = Int((CFAbsoluteTimeGetCurrent() - visionStart) * 1000)
        let usageNote = response.usage.map {
            "tokens prompt=\($0.promptTokens) completion=\($0.completionTokens) total=\($0.totalTokens)"
        } ?? "tokens not reported by provider"
        DebugLog.log("vision", "describe: response received in \(visionMs)ms, \(usageNote)")

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
            screenshotBase64: base64, ocrTimeMs: visionMs,
            visionUsage: response.usage
        )
    }

    // MARK: - Vision API Request

    /// Send the screenshot to the configured vision model and return the
    /// response text plus the token usage the provider reported, if any.
    private func sendVisionRequest(
        imageBase64: String, imageWidth: Int, imageHeight: Int
    ) -> (text: String, usage: ChatCompletionUsage?)? {
        let baseURL = agentConfig.baseURL ?? defaultAgentBaseURL
        guard let url = URL(string: baseURL + "/v1/chat/completions") else { return nil }

        let systemPrompt = loadSystemPrompt(.screenDescribe)

        // Build multipart content with image for OpenAI-compatible vision API.
        // Include the resized image dimensions so the model returns coordinates
        // in the correct pixel space regardless of macOS zoom mode.
        let userContent: [[String: Any]] = [
            ["type": "text", "text": "This image is \(imageWidth)x\(imageHeight) pixels. "
                + "Coordinates are in pixel space (0 to \(imageWidth) for x, 0 to \(imageHeight) for y)."],
            ["type": "image_url", "image_url": [
                "url": "data:image/png;base64,\(imageBase64)",
            ]],
        ]

        let route = Self.visionRoute(agentConfig: agentConfig, visionModelOverride: EnvConfig.visionModel)

        let requestBody: [String: Any] = [
            "model": route.model,
            "max_tokens": EnvConfig.visionMaxTokens,
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

        guard let responseData = sendRequest(
            route.transport, url, headers, body, EnvConfig.embacleTimeoutSeconds
        ) else {
            return nil
        }

        guard let text = extractChatCompletionText(from: responseData) else { return nil }
        return (text, ChatCompletionUsage.parse(from: responseData))
    }

    /// The model a vision request sends and the transport that carries it.
    /// A non-empty `visionModelOverride` (the `visionModel` setting) wins over the
    /// agent's own model, so vision runs on the same model as every other call unless
    /// told otherwise. The transport follows the model actually sent, since an
    /// override such as `claude:opus` selects an embacle-server runner over HTTP.
    static func visionRoute(
        agentConfig: AgentConfig,
        visionModelOverride: String,
        embeddedRunnerEnabled: Bool = AgentTransport.embeddedRunnerEnabled
    ) -> (model: String, transport: AgentTransport) {
        let model = visionModelOverride.isEmpty
            ? agentConfig.model ?? defaultAgentModel
            : visionModelOverride
        let transport = AgentTransport.resolve(
            provider: agentConfig.provider, model: model,
            embeddedRunnerEnabled: embeddedRunnerEnabled)
        return (model, transport)
    }
}
