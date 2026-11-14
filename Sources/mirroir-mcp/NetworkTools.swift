// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the set_network MCP tool for toggling network settings on iPhone.
// ABOUTME: Parses the mode and delegates the Settings procedure to NetworkToggle.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerNetworkTools(
        server: MCPServer,
        registry: TargetRegistry
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
