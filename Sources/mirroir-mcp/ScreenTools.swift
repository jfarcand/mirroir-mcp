// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers screen-related MCP tools: screenshot, describe_screen, start/stop recording.
// ABOUTME: Each tool maps MCP JSON-RPC calls to the capture, recorder, and describer subsystems.

import CoreGraphics
import Foundation
import HelperLib

extension MirroirMCP {
    /// The `settle_ms` argument of the screenshot and describe_screen tools in
    /// microseconds, or nil when absent. Negative values clamp to 0 and values
    /// past `frameSettleMaxTimeoutUs` clamp to it, so no input can overflow the
    /// conversion or hold the handler for longer than the cap.
    static func settleTimeoutUs(from args: [String: JSONValue]) -> UInt32? {
        guard let ms = args["settle_ms"]?.asInt() else { return nil }
        let maxMs = Int(EnvConfig.frameSettleMaxTimeoutUs / 1000)
        return UInt32(clamping: min(max(0, ms), maxMs)) * 1000
    }

    static func registerScreenTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        // screenshot — capture the mirroring window
        server.registerTool(MCPToolDefinition(
            name: "screenshot",
            description: """
                Capture a screenshot of the iPhone Mirroring window. \
                Returns the current screen content as a PNG image. \
                Use this to see what is displayed on the mirrored iPhone.

                By default the capture waits for the screen to stop changing, \
                because the mirrored frame lags the device: a capture taken \
                immediately after an action can still show the pre-action \
                screen. Never retry an action that "looks like a no-op" — the \
                first one landed, so the retry fires on the next screen and \
                mis-taps. Use settle_ms to tune the wait, or 0 to disable it.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "settle_ms": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "How long to wait for two consecutive identical frames before "
                            + "returning, in milliseconds. 0 returns the first frame "
                            + "immediately, which may be stale. Defaults to the "
                            + "frameSettleTimeoutUs setting."),
                    ]),
                    "scale": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Optional output scale factor in (0, 1] to downscale the returned "
                            + "PNG and cut its vision-token cost. 1 (default) keeps full "
                            + "resolution; 0.5 halves each dimension (~4x fewer pixels)."),
                    ]),
                    "region": .object([
                        "type": .string("array"),
                        "description": .string(
                            "Optional crop rectangle [x, y, width, height] in window points "
                            + "(same 0,0 = top-left space as tap coordinates). Returns only "
                            + "that sub-rectangle, cutting token cost. Omit for the full frame."),
                    ]),
                ]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let bridge = ctx.bridge
                let capture = ctx.capture

                guard bridge.findProcess() != nil else {
                    return .error("Target '\(ctx.name)' is not running")
                }

                let state = bridge.getState()
                if state == .paused {
                    if let menuBridge = bridge as? (any MenuActionCapable) {
                        _ = menuBridge.pressResume()
                        usleep(EnvConfig.resumeFromPausedUs)
                    }
                }

                // A settle window of 0 is an explicit opt-out: the caller wants
                // the first available frame and accepts that it may be stale.
                let settleUs = settleTimeoutUs(from: args) ?? EnvConfig.frameSettleTimeoutUs
                guard let captured = capture.captureSettledWithInfo(timeoutUs: settleUs) else {
                    return .error(
                        "Failed to capture screenshot. Is the '\(ctx.name)' window visible?")
                }

                // Optional token lever: crop to a region and/or downscale before
                // returning, so a caller (e.g. a kind:game scene loop) can trade
                // frame detail for fewer vision tokens per frame.
                let scale = args["scale"]?.asNumber()
                var region: CGRect?
                if case .array(let r)? = args["region"], r.count == 4,
                   let x = r[0].asNumber(), let y = r[1].asNumber(),
                   let w = r[2].asNumber(), let h = r[3].asNumber() {
                    region = CGRect(x: x, y: y, width: w, height: h)
                }

                let pngData: Data
                if scale != nil || region != nil {
                    guard let transformed = ScreenshotRegionScaler.transform(
                        pngData: captured.data, windowSize: captured.info.size,
                        region: region, scale: scale
                    ) else {
                        return .error("Failed to apply scale/region to the screenshot")
                    }
                    pngData = transformed
                } else {
                    pngData = captured.data
                }

                return .image(pngData.base64EncodedString())
            }
        ))

        // describe_screen — OCR-based screen element detection with tap coordinates
        server.registerTool(MCPToolDefinition(
            name: "describe_screen",
            description: """
                Analyze the iPhone screen using OCR and return all visible text elements \
                with their exact tap coordinates. Use this instead of visually estimating \
                positions from screenshots. Returns both a structured text list of elements \
                and the screenshot image. Coordinates are in the same point system as the \
                tap tool (0,0 = top-left of mirroring window). \
                Set scroll to true to scroll through the full page and collect all elements \
                with page-absolute Y coordinates. \
                With screenDescriberMode set to vision, elements come from an LLM vision \
                call instead of OCR and their coordinates are approximate: elements near \
                the bottom of the screen can come back placed too high. \
                The call first waits for the screen to stop changing, because the mirrored \
                frame lags the device: a frame taken right after an action can still show \
                the pre-action screen (and in vision mode a transitional frame would still \
                be billed). Use settle_ms to tune the wait, or 0 on a constantly animated \
                screen such as a game, which never settles.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "scroll": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Scroll through the full page to collect all elements with page-absolute Y coordinates (default: false)"),
                    ]),
                    "omit_screenshot": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Omit the screenshot image from the response to save context window space (default: uses MIRROIR_OMIT_SCREENSHOT env var, or false)"),
                    ]),
                    "settle_ms": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "How long to wait for two consecutive identical frames before "
                            + "describing, in milliseconds. 0 describes the first frame, "
                            + "which may be stale. Defaults to the frameSettleTimeoutUs "
                            + "setting in both OCR and vision mode."),
                    ]),
                ]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let bridge = ctx.bridge
                let describer = ctx.describer

                guard bridge.findProcess() != nil else {
                    return .error("Target '\(ctx.name)' is not running")
                }
                let state = bridge.getState()
                if state == .paused {
                    if let menuBridge = bridge as? (any MenuActionCapable) {
                        _ = menuBridge.pressResume()
                        usleep(EnvConfig.resumeFromPausedUs)
                    }
                }

                let scrollEnabled = args["scroll"]?.asBool() ?? false
                let omitScreenshot = args["omit_screenshot"]?.asBool() ?? EnvConfig.describeScreenOmitScreenshot

                // Full-page scroll mode: collect all elements across viewports
                if scrollEnabled {
                    let input = ctx.input
                    guard let scrollResult = describer.describeFullPage(
                        input: input, bridge: bridge
                    ) else {
                        return .error(
                            "Failed to capture/analyze screen. Is the '\(ctx.name)' window visible?")
                    }

                    var lines = ["Screen elements (page-absolute tap coordinates in points):"]
                    for el in scrollResult.elements.sorted(by: { $0.tapY < $1.tapY }) {
                        lines.append("- \"\(el.text)\" at (\(Int(el.tapX)), \(Int(el.tapY)))")
                    }
                    if scrollResult.elements.isEmpty {
                        lines.append("(no text detected)")
                    }
                    lines.append("")
                    lines.append("_meta: scroll_count=\(scrollResult.scrollCount) total_offset=\(Int(scrollResult.totalScrollOffset)) element_count=\(scrollResult.elements.count)")
                    let description = lines.joined(separator: "\n")

                    let scrollContent: [MCPContent] = omitScreenshot
                        ? [.text(description)]
                        : [.text(description), .image(scrollResult.screenshotBase64, mimeType: "image/png")]
                    return MCPToolResult(content: scrollContent, isError: false)
                }

                // A client describe usually follows an action, so it settles by
                // default in every describer mode, exactly like the screenshot
                // tool. Server-internal polls call describe() without a window
                // and keep the describer's own (OCR: no settle) policy.
                let settleUs = settleTimeoutUs(from: args) ?? EnvConfig.frameSettleTimeoutUs
                guard let result = describer.describe(settleTimeoutUs: settleUs) else {
                    return .error(
                        "Failed to capture/analyze screen. Is the '\(ctx.name)' window visible?")
                }

                var lines = ["Screen elements (tap coordinates in points):"]
                for el in result.elements.sorted(by: { $0.tapY < $1.tapY }) {
                    lines.append("- \"\(el.text)\" at (\(Int(el.tapX)), \(Int(el.tapY)))")
                }
                if let failure = result.ocrFailure {
                    // Never report a broken engine as a blank screen: the two
                    // look identical in the element list and only one of them
                    // means the screen is actually empty.
                    lines.append("(OCR FAILED — text recognition did not run: \(failure))")
                    lines.append("Any icons and hints below come from the non-OCR path; "
                        + "the text layer is missing, not empty.")
                } else if result.screenBlank {
                    lines.append("(SCREEN BLANK — the frame is a uniform fill with no text or "
                        + "icons: the device is transitioning (rotation, launch, scene change). "
                        + "Describe again once the screen has drawn.)")
                } else if result.elements.isEmpty {
                    lines.append("(no text detected)")
                }
                if !result.icons.isEmpty {
                    lines.append("")
                    lines.append("Unlabeled icons (estimated positions):")
                    for icon in result.icons.sorted(by: { $0.tapX < $1.tapX }) {
                        lines.append("- Icon at (\(Int(icon.tapX)), \(Int(icon.tapY))), ~\(Int(icon.estimatedSize))x\(Int(icon.estimatedSize))pt")
                    }
                }
                if !result.hints.isEmpty {
                    lines.append("")
                    lines.append("Hints:")
                    for hint in result.hints {
                        lines.append("- \(hint)")
                    }
                }
                lines.append("")
                lines.append("_meta: ocr_time_ms=\(result.ocrTimeMs) recognition_level=\(EnvConfig.ocrRecognitionLevel) element_count=\(result.elements.count)"
                    + (result.ocrFailure == nil ? "" : " ocr_status=failed")
                    + (result.screenBlank ? " screen_blank=true" : "")
                    + (result.visionUsage.map {
                        " vision_prompt_tokens=\($0.promptTokens)"
                            + " vision_completion_tokens=\($0.completionTokens)"
                            + " vision_total_tokens=\($0.totalTokens)"
                    } ?? ""))
                let description = lines.joined(separator: "\n")

                let content: [MCPContent] = omitScreenshot
                    ? [.text(description)]
                    : [.text(description), .image(result.screenshotBase64, mimeType: "image/png")]
                return MCPToolResult(content: content, isError: false)
            }
        ))

        // start_recording — begin video recording of the mirroring window
        server.registerTool(MCPToolDefinition(
            name: "start_recording",
            description: """
                Start recording a video of the mirrored iPhone screen. \
                Records the iPhone Mirroring window as a .mov file. \
                Use stop_recording to end the recording and get the file path. \
                Requires Screen Recording permission in System Preferences.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "output_path": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional file path for the recording (default: temp directory)"),
                    ])
                ]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let recorder = ctx.recorder

                let outputPath = args["output_path"]?.asString()

                if let error = recorder.startRecording(outputPath: outputPath) {
                    return .error(error)
                }
                return .text("Recording started")
            }
        ))

        // stop_recording — stop video recording and return the file path
        server.registerTool(MCPToolDefinition(
            name: "stop_recording",
            description: """
                Stop the current video recording and return the file path. \
                Must be called after start_recording. Returns the path to \
                the recorded .mov file.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let recorder = ctx.recorder

                let result = recorder.stopRecording()
                if let error = result.error {
                    return .error(error)
                }
                guard let path = result.filePath else {
                    return .error("Recording stopped but no file was produced")
                }
                return .text("Recording saved to: \(path)")
            }
        ))
    }
}
