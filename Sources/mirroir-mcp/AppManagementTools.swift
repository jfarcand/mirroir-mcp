// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the reset_app MCP tool for force-quitting apps via the App Switcher.
// ABOUTME: Launches the app first via Spotlight (handles localization), then dismisses its card.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerAppManagementTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        // reset_app — force-quit an app via the App Switcher
        server.registerTool(MCPToolDefinition(
            name: "reset_app",
            description: """
                Force-quit an app on the mirrored iPhone by launching it via Spotlight \
                (which handles localization), opening the App Switcher where the \
                just-launched app is the centered card, and swiping it up to dismiss. \
                Use this before launch_app to ensure a fresh start.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("The app name to force-quit"),
                    ])
                ]),
                "required": .array([.string("name")]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                guard let menuBridge = ctx.bridge as? (any MenuActionCapable) else {
                    return .error("Target '\(ctx.name)' does not support reset_app")
                }
                guard let appName = args["name"]?.asString() else {
                    return .error("Missing required parameter: name (string)")
                }
                if let error = AppSwitcherDismissal.forceQuit(
                    appName: appName,
                    input: ctx.input,
                    bridge: ctx.bridge,
                    menuBridge: menuBridge,
                    describer: ctx.ocrDescriber
                ) {
                    return .error(error)
                }
                return .text("Force-quit '\(appName)'")
            }
        ))
    }
}
