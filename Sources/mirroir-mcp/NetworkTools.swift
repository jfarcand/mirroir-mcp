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
        // set_network — toggle network settings via Control Center or the Settings app
        server.registerTool(MCPToolDefinition(
            name: "set_network",
            description: """
                Set Airplane Mode, Wi-Fi or cellular data on the mirrored iPhone: in \
                Control Center when iPhone Mirroring gives it (macOS 27 with an iPhone \
                on iOS 27), otherwise in the Settings app. The switch is read first and \
                tapped only when it is not already in the asked state, then read again; \
                the result says what it shows. A switch that cannot be read (in \
                Settings, a menu, as cellular data is with two SIMs, or the dark \
                appearance) is refused without a tap. airplane_on and wifi_off can cut iPhone Mirroring's connection, \
                and only the iPhone can then turn them back. Modes: airplane_on, \
                airplane_off, wifi_on, wifi_off, cellular_on, cellular_off. Returns to \
                the home screen afterwards.
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
                switch NetworkToggle.toggle(
                    mode: mode, input: ctx.input, describer: ctx.ocrDescriber,
                    controlCenterDescriber: ctx.describer, menuBridge: menuBridge, settleUs: EnvConfig.toolSettlingDelayUs,
                    settingsRefusal: {
                        guard case .denied(let reason) = policy.checkAppLaunch(
                            NetworkToggle.settingsAppName) else { return nil }
                        return reason
                    }
                ) {
                case .success(let message): return .text(message)
                case .failure(let error): return .error(error.message)
                }
            }
        ))
    }
}
