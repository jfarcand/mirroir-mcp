// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the calibrate_component MCP tool for validating component definition files.
// ABOUTME: Thin handler that parses args, reads the definition file, and delegates to ComponentTester.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerComponentTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        // calibrate_component — validate a component definition against the live screen
        server.registerTool(MCPToolDefinition(
            name: "calibrate_component",
            description: """
                Test a component definition (.md file) against the current iPhone screen. \
                OCRs the screen, runs component detection with the given definition, \
                and returns a full diagnostic report showing what matched, what didn't, \
                and why. Use this to validate and debug component definitions without \
                running a full exploration.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "component_path": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Path to a .md component definition file"),
                    ]),
                    "target": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Target name for multi-target setups (optional)"),
                    ]),
                    "scroll": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Scroll through the full page to collect all elements (default: false)"),
                    ]),
                ]),
                "required": .array([.string("component_path")]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let bridge = ctx.bridge
                let input = ctx.input
                let describer = ctx.describer

                // Parse component_path argument
                guard let componentPath = args["component_path"]?.asString(),
                      !componentPath.isEmpty else {
                    return .error("component_path is required")
                }

                let scrollEnabled = args["scroll"]?.asBool() ?? false

                // Validate file extension and resolve symlinks to prevent path traversal
                let fileURL = URL(fileURLWithPath: componentPath)
                    .standardized.resolvingSymlinksInPath()
                guard fileURL.pathExtension == "md" else {
                    return .error("component_path must be a .md file")
                }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    return .error("Cannot read file: \(componentPath)")
                }

                let stem = fileURL.deletingPathExtension().lastPathComponent
                guard let definition = ComponentSkillParser.parseValidated(
                    content: content, fallbackName: stem
                ) else {
                    return .error("Component '\(stem)' has invalid keys — check DebugLog for details")
                }

                // Verify target is running
                guard bridge.findProcess() != nil else {
                    return .error("Target '\(ctx.name)' is not running")
                }

                // Resume if paused
                let state = bridge.getState()
                if state == .paused {
                    if let menuBridge = bridge as? (any MenuActionCapable) {
                        _ = menuBridge.pressResume()
                        usleep(EnvConfig.resumeFromPausedUs)
                    }
                }

                // Collect OCR elements: single viewport or full-page scroll
                let elements: [TapPoint]
                let screenshotBase64: String

                if scrollEnabled {
                    guard let scrollResult = describer.describeFullPage(
                        input: input, bridge: bridge
                    ) else {
                        return .error(ScreenReadFailure.message(
                            "Failed to capture/analyze screen.", targetName: ctx.name,
                            state: ctx.bridge.getState()))
                    }
                    elements = scrollResult.elements
                    screenshotBase64 = scrollResult.screenshotBase64
                } else {
                    guard let result = describer.describe() else {
                        return .error(ScreenReadFailure.message(
                            "Failed to capture/analyze screen.", targetName: ctx.name,
                            state: ctx.bridge.getState()))
                    }
                    elements = result.elements
                    screenshotBase64 = result.screenshotBase64
                }

                // Get screen height for zone calculation
                let screenHeight = bridge.getWindowInfo()?.size.height ?? 0

                // Load all definitions for comparison
                let allDefinitions = ComponentLoader.loadAll()

                // Generate diagnostic report
                let report = ComponentTester.diagnose(
                    definition: definition,
                    elements: elements,
                    screenHeight: screenHeight,
                    allDefinitions: allDefinitions
                )

                return MCPToolResult(
                    content: [
                        .text(report),
                        .image(screenshotBase64, mimeType: "image/png"),
                    ],
                    isError: false
                )
            }
        ))

        registerClassifyScreen(server: server, registry: registry)
    }

    /// classify_screen — group the current screen's elements into components
    /// using a model. Where the model belongs to the MCP client, the call ends
    /// with an `input_required` result and completes on the client's retry.
    private static func registerClassifyScreen(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        /// Ceiling for the classification reply.
        let maxTokens = 2000

        server.registerTool(MCPToolDefinition(
            name: "classify_screen",
            description: """
                Group the current screen's OCR elements into UI components using an AI model. \
                Returns each detected component, its definition, and the elements it covers. \
                Use this to see how a screen decomposes before writing component definitions \
                or running an exploration.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Target name for multi-target setups (optional)"),
                    ]),
                ]),
            ],
            contextualHandler: { args, context in
                let definitions = ComponentLoader.loadAll()
                guard !definitions.isEmpty else {
                    return .error("No component definitions found to classify against")
                }

                // A retry: the client answered, and the state names the screen
                // the question was asked about.
                if let reply = ScreenClassification.replyText(from: context) {
                    guard let screen = ScreenClassification.resumeScreen(from: context) else {
                        return .error(
                            "The follow-up state was missing, altered, or expired — "
                            + "call classify_screen again to restart the classification")
                    }
                    guard let components = ScreenClassification.components(
                        fromReply: reply, screen: screen, definitions: definitions
                    ) else {
                        return .error("The model's reply could not be read as components")
                    }
                    return .text(ScreenClassificationReport.format(
                        components: components, elementCount: screen.elements.count))
                }

                // A first attempt: capture the screen, then ask.
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                guard let described = ctx.describer.describe() else {
                    return .error("Could not read the screen")
                }
                guard let windowSize = ctx.bridge.getWindowInfo()?.size else {
                    return .error("Could not read the window size")
                }
                let screen = ScreenClassification.CapturedScreen(
                    elements: described.elements, screenHeight: windowSize.height)
                guard !screen.elements.isEmpty else {
                    return .error("No elements on screen to classify")
                }

                // The client's own model answers over the round trip; otherwise
                // the agent configured here answers inline.
                if server.clientSupportsSampling() {
                    return ScreenClassification.askClient(
                        screen, definitions: definitions, maxTokens: maxTokens)
                }
                guard let agentConfig = AIAgentRegistry.resolveConfigured() else {
                    return .error(
                        "No model available: the client offers no sampling capability and "
                        + "no AI agent is configured here")
                }
                let classified = ElementClassifier.classify(
                    screen.elements, screenHeight: screen.screenHeight)
                guard let components = AgentClassifier(agentConfig: agentConfig).classify(
                    classified: classified, definitions: definitions,
                    screenHeight: screen.screenHeight
                ) else {
                    return .error("The agent did not return a usable classification")
                }
                return .text(ScreenClassificationReport.format(
                    components: components, elementCount: screen.elements.count))
            }
        ))
    }
}
