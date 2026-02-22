// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the generate_skill MCP tool for AI-driven app exploration.
// ABOUTME: Session-based workflow: start (launch + OCR) → capture (OCR each screen) → finish (emit SKILL.md).

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerGenerateSkillTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        let session = ExplorationSession()

        server.registerTool(MCPToolDefinition(
            name: "generate_skill",
            description: """
                Generate a SKILL.md by exploring an app. Session-based workflow: \
                (1) action="start" — launch app, OCR first screen, begin session. \
                (2) Use tap/swipe/type_text to navigate, then action="capture" to OCR each screen. \
                (3) action="finish" — assemble captured screens into a SKILL.md and return it.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Session action: \"start\" to launch app and begin, " +
                            "\"capture\" to OCR current screen and append, " +
                            "\"finish\" to generate SKILL.md from all captures."),
                        "enum": .array([
                            .string("start"),
                            .string("capture"),
                            .string("finish"),
                        ]),
                    ]),
                    "app_name": .object([
                        "type": .string("string"),
                        "description": .string(
                            "App to explore (required for start action)."),
                    ]),
                    "goal": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional flow description, e.g. \"check software version\" (for start action)."),
                    ]),
                    "arrived_via": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Element tapped to reach current screen, e.g. \"General\" (for capture action)."),
                    ]),
                    "action_type": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Action performed to reach current screen: " +
                            "\"tap\", \"swipe\", \"type\", \"press_key\", \"scroll_to\", " +
                            "\"long_press\" (for capture action)."),
                    ]),
                ]),
                "required": .array([.string("action")]),
            ],
            handler: { args in
                guard let action = args["action"]?.asString() else {
                    return .error("Missing required parameter: action")
                }

                switch action {
                case "start":
                    return handleStart(args: args, session: session, registry: registry)
                case "capture":
                    return handleCapture(args: args, session: session, registry: registry)
                case "finish":
                    return handleFinish(session: session)
                default:
                    return .error("Unknown action '\(action)'. Use: start, capture, finish.")
                }
            }
        ))
    }

    // MARK: - Action Handlers

    private static func handleStart(
        args: [String: JSONValue],
        session: ExplorationSession,
        registry: TargetRegistry
    ) -> MCPToolResult {
        guard let appName = args["app_name"]?.asString(), !appName.isEmpty else {
            return .error("Missing required parameter: app_name (for start action)")
        }

        if session.active {
            return .error(
                "An exploration session is already active for '\(session.currentAppName)'. " +
                "Call finish first or start a new session.")
        }

        let (ctx, err) = registry.resolveForTool(args)
        guard let ctx else { return err! }

        // Launch the app
        if let launchError = ctx.input.launchApp(name: appName) {
            return .error("Failed to launch '\(appName)': \(launchError)")
        }

        // Wait for app to settle
        usleep(EnvConfig.stepSettlingDelayMs * 1000)

        // Start session
        let goal = args["goal"]?.asString() ?? ""
        session.start(appName: appName, goal: goal)

        // OCR first screen
        guard let result = ctx.describer.describe(skipOCR: false) else {
            return .error(
                "Failed to capture/analyze screen after launching '\(appName)'. " +
                "Is the target window visible?")
        }

        // Capture first screen (no action since this is the initial screen)
        session.capture(
            elements: result.elements,
            hints: result.hints,
            actionType: nil,
            arrivedVia: nil,
            screenshotBase64: result.screenshotBase64
        )

        let description = formatScreenDescription(
            elements: result.elements,
            hints: result.hints,
            preamble: "Exploration started for '\(appName)'. Screen 1 captured."
        )

        return MCPToolResult(
            content: [
                .text(description),
                .image(result.screenshotBase64, mimeType: "image/png"),
            ],
            isError: false
        )
    }

    private static func handleCapture(
        args: [String: JSONValue],
        session: ExplorationSession,
        registry: TargetRegistry
    ) -> MCPToolResult {
        guard session.active else {
            return .error("No active exploration session. Call generate_skill with action=\"start\" first.")
        }

        let (ctx, err) = registry.resolveForTool(args)
        guard let ctx else { return err! }

        // OCR current screen
        guard let result = ctx.describer.describe(skipOCR: false) else {
            return .error("Failed to capture/analyze screen. Is the target window visible?")
        }

        let arrivedVia = args["arrived_via"]?.asString()
        let actionType = args["action_type"]?.asString()

        let accepted = session.capture(
            elements: result.elements,
            hints: result.hints,
            actionType: actionType,
            arrivedVia: arrivedVia,
            screenshotBase64: result.screenshotBase64
        )

        if !accepted {
            return .text(
                "Screen unchanged — capture skipped (duplicate of previous screen). " +
                "Try a different action before capturing again.")
        }

        let screenNum = session.screenCount
        let description = formatScreenDescription(
            elements: result.elements,
            hints: result.hints,
            preamble: "Screen \(screenNum) captured\(arrivedVia.map { " (arrived via \"\($0)\")" } ?? "")."
        )

        return MCPToolResult(
            content: [
                .text(description),
                .image(result.screenshotBase64, mimeType: "image/png"),
            ],
            isError: false
        )
    }

    private static func handleFinish(session: ExplorationSession) -> MCPToolResult {
        guard session.active else {
            return .error("No active exploration session. Call generate_skill with action=\"start\" first.")
        }

        guard session.screenCount > 0 else {
            return .error("No screens captured. Use capture action before finishing.")
        }

        guard let data = session.finalize() else {
            return .error("Failed to finalize exploration session.")
        }

        let skillMd = SkillMdGenerator.generate(
            appName: data.appName,
            goal: data.goal,
            screens: data.screens
        )

        return .text(skillMd)
    }

    // MARK: - Formatting

    /// Format OCR elements and hints into a text description.
    /// Same pattern as describe_screen in ScreenTools.swift.
    private static func formatScreenDescription(
        elements: [TapPoint],
        hints: [String],
        preamble: String
    ) -> String {
        var lines = [preamble, "", "Screen elements (tap coordinates in points):"]
        for el in elements.sorted(by: { $0.tapY < $1.tapY }) {
            lines.append("- \"\(el.text)\" at (\(Int(el.tapX)), \(Int(el.tapY)))")
        }
        if elements.isEmpty {
            lines.append("(no text detected)")
        }
        if !hints.isEmpty {
            lines.append("")
            lines.append("Hints:")
            for hint in hints {
                lines.append("- \(hint)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
