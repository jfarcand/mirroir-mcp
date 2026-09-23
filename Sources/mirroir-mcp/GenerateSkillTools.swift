// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the generate_skill MCP tool for AI-driven app exploration.
// ABOUTME: Session-based workflow: start (launch + OCR) -> capture (OCR + guidance) -> finish (emit SKILL.md).

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerGenerateSkillTools(
        server: MCPServer,
        registry: TargetRegistry,
        policy: PermissionPolicy
    ) {
        let session = ExplorationSession()

        server.registerTool(MCPToolDefinition(
            name: "generate_skill",
            description: """
                Generate a SKILL.md by exploring an app. Session-based workflow: \
                (1) action="start" \u{2014} launch app + OCR. \
                (2) Navigate with tap/swipe/type_text, then action="capture" per screen. \
                (3) action="finish" \u{2014} emit SKILL.md. \
                Use action="explore" for autonomous exploration (BFS default, or DFS). \
                Set fresh=true to discard persisted graph and explore from scratch. \
                WARNING: Exploration steals Mac keyboard focus (global HID events). \
                SECURITY: May navigate into sensitive screens. Do not run unattended.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Session action: \"start\" to launch app and begin, " +
                            "\"capture\" to OCR current screen and append, " +
                            "\"finish\" to generate SKILL.md from all captures, " +
                            "\"explore\" for autonomous exploration (BFS or DFS)."),
                        "enum": .array([
                            .string("start"),
                            .string("capture"),
                            .string("finish"),
                            .string("explore"),
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
                            "Optional flow description, e.g. \"check software version\" (for start action). " +
                            "Omit for discovery mode."),
                    ]),
                    "goals": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Optional array of goals for manifest mode. " +
                            "Each goal is explored in sequence, producing one SKILL.md per goal."),
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
                            "\"long_press\", \"remember\", \"screenshot\", \"press_home\", " +
                            "\"open_url\" (for capture action)."),
                    ]),
                    "max_depth": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Maximum BFS depth for explore action (default: 6)."),
                    ]),
                    "max_screens": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Maximum screens to visit for explore action (default: 30)."),
                    ]),
                    "max_time": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Maximum seconds for explore action (default: 300)."),
                    ]),
                    "strategy": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Override exploration strategy: \"mobile\" (default), " +
                            "\"social\" (Reddit, Instagram, TikTok), " +
                            "\"desktop\" (generic macOS windows). " +
                            "Auto-detected from target type and app name if omitted."),
                        "enum": .array([
                            .string("mobile"),
                            .string("social"),
                            .string("desktop"),
                        ]),
                    ]),
                    "fresh": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "When true, discard any persisted navigation graph and " +
                            "explore from scratch. Default: true. Set false for incremental exploration."),
                    ]),
                    "seed": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Seed for deterministic exploration ordering. " +
                            "Same seed produces identical exploration sequences."),
                    ]),
                    "skip_calibration": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Skip component detection and validation during calibration. " +
                            "Full-page scrolling still runs to discover below-fold elements. " +
                            "Useful with vision describers that produce clean semantic elements. Default: false."),
                    ]),
                    "explorer": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Exploration algorithm: \"bfs\" (breadth-first, default) " +
                            "or \"dfs\" (depth-first)."),
                        "enum": .array([
                            .string("bfs"),
                            .string("dfs"),
                        ]),
                    ]),
                    "emit": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "When true on the finish or explore action, write a runner-consumable " +
                            ".mirroir/apps/<app>/ iOS leg (the captured walk + the cross-surface " +
                            "baseline the web leg's cross_surface: step compares against) into " +
                            "the consumer repo. Default: false."),
                    ]),
                    "output_dir": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Consumer repo root the emit=true tree is written under " +
                            "(<output_dir>/.mirroir/apps/<app>/). Defaults to walking up from " +
                            "the working directory; emitting into ~/.mirroir is refused."),
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
                    return handleFinish(
                        session: session, emit: args["emit"]?.asBool() ?? false,
                        outputDir: args["output_dir"]?.asString())
                case "explore":
                    return handleExplore(
                        args: args, session: session,
                        registry: registry, server: server, policy: policy
                    )
                default:
                    return .error("Unknown action '\(action)'. Use: start, capture, finish, explore.")
                }
            }
        ))
    }
}
