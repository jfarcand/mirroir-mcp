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
        // The passing runs of this server's session, by task label.
        let drafts = TaskDraft()
        server.registerTool(MCPToolDefinition(
            name: "run_steps",
            description: """
                Run several steps on the mirrored iPhone in one call, once you have \
                seen each of them work: one round trip instead of one per action. \
                Each step uses the skill grammar: "launch: Weather", "tap: <text on screen>" \
                (found by OCR, so read it from describe_screen first: it is in the iPhone's \
                language), "tap: @324,113" \
                (a point from describe_screen, for controls with no readable text), \
                "type: calculator", "clear_field" (empties the focused field before \
                a type), "press_key: return", \
                "wait_for: Get", "assert_visible: Results", "swipe: up", \
                "scroll_to: Privacy", "home", and a checked action: \
                "condition: visible \"Allow\" -> tap: Allow" (runs only when the element \
                shows) or "repeat: until visible \"Done\", max 8 -> swipe: up" (runs until it \
                shows, at most max times). Every step must be allowed by the \
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
                    "task": .object([
                        "type": .string("string"),
                        "description": .string(
                            "The task these steps do, in a few words, e.g. \"order a coffee\". When every "
                            + "step passes, the reply ends with a SKILL.md draft of all the passing runs "
                            + "given this task in this session, ready to save as a skill."),
                    ]),
                ]),
                "required": .array([.string("steps")]),
            ],
            contextualHandler: { args, context in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                guard case .array(let values) = args["steps"] else {
                    return .error("Missing required parameter: steps (array of strings)")
                }
                let raw = values.compactMap { $0.asString() }
                guard raw.count == values.count else {
                    return .error("Every step must be a string such as \"type: calculator\".")
                }
                let task = args["task"]?.asString()?.trimmingCharacters(in: .whitespaces)
                if let task, let refusal = TaskDraft.refusal(of: task) {
                    return .error("\(refusal). Nothing was run.")
                }
                switch InlineStepRunner.prepare(raw, policy: policy) {
                case .failure(let refusal):
                    return .error(refusal.message)
                case .success(let steps):
                    let executor = InlineStepRunner.executor(for: ctx, registry: registry, call: context.call)
                    let report = InlineStepRunner.run(steps, executor: executor, policy: policy)
                    let text = task.map { report.text + "\n\n" + drafts.note(task: $0, report: report, steps: steps) }
                        ?? report.text
                    return report.failed ? .error(text) : .text(text)
                }
            }
        ))
    }
}
