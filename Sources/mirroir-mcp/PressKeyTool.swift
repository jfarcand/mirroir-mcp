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
// ABOUTME: Registers press_key: a special key or shortcut sent to the target, with optional modifiers.
// ABOUTME: Split from InputTools.swift; takes `expect` like tap and swipe.

import Foundation
import HelperLib

extension MirroirMCP {
    /// press_key, with the `expect` check the pointing tools share (carnet#96).
    static func registerPressKeyTool(
        server: MCPServer,
        registry: TargetRegistry,
        policy: PermissionPolicy
    ) {
        // press_key — send a special key press with optional modifiers
        server.registerTool(MCPToolDefinition(
            name: "press_key",
            description: """
                Send a key press to the mirrored iPhone with optional modifiers. \
                On iPhone Mirroring through macOS 26 the key goes to its window without \
                bringing it to the front; on a later macOS, and on other targets, the window \
                is activated first. \
                Supported keys: return, escape, tab, delete, space, up, down, left, right, \
                or any single character (a-z, 0-9, etc.) for shortcuts. \
                Optional modifiers: command, shift, option, control. \
                Examples: press Return to confirm, Escape to cancel, Ctrl+Cmd+Z for shake. \
                Give `expect` with the text the key should lead to: the call waits for it \
                and fails when it never shows.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object(ActionExpectation.properties.merging([
                    "key": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Key name: return, escape, tab, delete, space, up, down, left, right, or a single character"),
                    ]),
                    "modifiers": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                        ]),
                        "description": .string(
                            "Optional modifier keys: command, shift, option, control"),
                    ]),
                ]) { $1 }),
                "required": .array([.string("key")]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let input = ctx.input

                guard let keyName = args["key"]?.asString() else {
                    return .error("Missing required parameter: key (string)")
                }

                let modifiers = args["modifiers"]?.asStringArray() ?? []
                let expectation: ActionExpectation?
                switch ActionExpectation.parse(args) {
                case .success(let parsed): expectation = parsed
                case .failure(let refusal): return .error(refusal.message)
                }

                let result = input.pressKey(
                    keyName: keyName, modifiers: modifiers
                )
                guard result.success else {
                    return .error(result.error ?? "Failed to press key")
                }

                let reply = modifiers.isEmpty
                    ? "Pressed \(keyName)"
                    : "Pressed \(modifiers.joined(separator: "+"))+\(keyName)"
                guard let expectation else { return .text(reply) }
                return ActionExpectation.check(
                    expectation, after: reply, ctx: ctx, registry: registry, policy: policy)
            }
        ))
    }
}
