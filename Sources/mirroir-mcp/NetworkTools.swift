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
// ABOUTME: Registers the set_network MCP tool for toggling network settings on iPhone.
// ABOUTME: Parses the mode and delegates the Settings procedure to NetworkToggle.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerNetworkTools(
        server: MCPServer,
        registry: TargetRegistry,
        policy: PermissionPolicy
    ) {
        // set_network — toggle network settings via the Settings app
        server.registerTool(MCPToolDefinition(
            name: "set_network",
            description: """
                Toggle network settings on the mirrored iPhone by navigating to the \
                Settings app and tapping the appropriate control. Supported modes: \
                airplane_on, airplane_off, wifi_on, wifi_off, cellular_on, cellular_off. \
                After toggling, returns to the home screen.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array(NetworkToggle.Mode.names.map { .string($0) }),
                        "description": .string(
                            "Network mode to set: airplane_on/off, wifi_on/off, cellular_on/off"),
                    ])
                ]),
                "required": .array([.string("mode")]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args, requiring: .setNetwork)
                guard let ctx else { return err! }
                guard let menuBridge = ctx.bridge as? (any MenuActionCapable) else {
                    return .error("Target '\(ctx.name)' does not support set_network")
                }
                guard let mode = args["mode"]?.asString() else {
                    return .error("Missing required parameter: mode (string)")
                }
                if case .denied(let reason) = policy.checkAppLaunch(NetworkToggle.settingsAppName) {
                    return .error(reason)
                }

                switch NetworkToggle.toggle(
                    mode: mode, input: ctx.input, describer: ctx.ocrDescriber,
                    menuBridge: menuBridge, settleUs: EnvConfig.toolSettlingDelayUs
                ) {
                case .success(let message): return .text(message)
                case .failure(let error): return .error(error.message)
                }
            }
        ))
    }
}
