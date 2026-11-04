// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the run_steps MCP tool: several proven skill steps in one call.
// ABOUTME: Parses the step list and delegates to InlineStepRunner, which checks permissions and runs them.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerRunStepsTools(
        server: MCPServer,
        registry: TargetRegistry,
        policy: PermissionPolicy
    ) {
        server.registerTool(MCPToolDefinition(
            name: "run_steps",
            description: """
                Run several steps on the mirrored iPhone in one call, once you have \
                seen each of them work: one round trip instead of one per action. \
                Each step uses the skill grammar: "launch: Weather", "tap: <text on screen>" \
                (found by OCR, so read it from describe_screen first: it is in the iPhone's \
                language), "tap: @324,113" \
                (a point from describe_screen, for controls with no readable text), \
                "type: calculator", "press_key: return", \
                "wait_for: Get", "assert_visible: Results", "swipe: up", \
                "scroll_to: Privacy", "home". Every step must be allowed by the \
                permission policy, or nothing runs. The run stops at the first \
                failed step and reports why; the reply ends with the text the \
                screen shows afterwards, so one describe_screen confirms the result.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "steps": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Steps in order, e.g. [\"tap: @324,113\", \"type: calculator\", "
                            + "\"press_key: return\", \"wait_for: Get\"]"),
                    ]),
                ]),
                "required": .array([.string("steps")]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                guard case .array(let values) = args["steps"] else {
                    return .error("Missing required parameter: steps (array of strings)")
                }
                let raw = values.compactMap { $0.asString() }
                guard raw.count == values.count else {
                    return .error("Every step must be a string such as \"type: calculator\".")
                }
                switch InlineStepRunner.prepare(raw, policy: policy) {
                case .failure(let refusal):
                    return .error(refusal.message)
                case .success(let steps):
                    let executor = InlineStepRunner.executor(for: ctx, registry: registry)
                    let report = InlineStepRunner.run(steps, executor: executor)
                    return report.failed ? .error(report.text) : .text(report.text)
                }
            }
        ))
    }
}
