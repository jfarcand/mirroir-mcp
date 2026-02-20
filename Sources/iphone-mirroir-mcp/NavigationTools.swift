// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers navigation-related MCP tools: launch_app, open_url, press_home, press_app_switcher, spotlight.
// ABOUTME: Each tool maps MCP JSON-RPC calls to the bridge and input subsystems for app navigation.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
    static func registerNavigationTools(
        server: MCPServer,
        registry: TargetRegistry,
        policy: PermissionPolicy
    ) {
        // launch_app — open an app by name via Spotlight search
        server.registerTool(MCPToolDefinition(
            name: "launch_app",
            description: """
                Launch an app on the mirrored iPhone by name using Spotlight search. \
                Opens Spotlight, types the app name, and presses Return to launch \
                the top result. The app name should match the display name shown \
                on the iPhone home screen.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("The app name to search for and launch"),
                    ])
                ]),
                "required": .array([.string("name")]),
            ],
            handler: { args in
                let ctx = registry.resolve(args["target"]?.asString())
                guard let ctx else { return .error("Unknown target '\(args["target"]?.asString() ?? "")'") }
                let input = ctx.input

                guard let appName = args["name"]?.asString() else {
                    return .error("Missing required parameter: name (string)")
                }

                let appDecision = policy.checkAppLaunch(appName)
                DebugLog.log("permission", "checkAppLaunch(\(appName))=\(appDecision)")
                if case .denied(let reason) = appDecision {
                    return .error(reason)
                }

                if let error = input.launchApp(name: appName) {
                    return .error(error)
                }
                return .text("Launched '\(appName)' via Spotlight")
            }
        ))

        // open_url — open a URL in Safari on the iPhone
        server.registerTool(MCPToolDefinition(
            name: "open_url",
            description: """
                Open a URL in Safari on the mirrored iPhone. \
                Launches Safari, selects the address bar, types the URL, \
                and navigates to it. Works with any URL including http, https, \
                and deep links.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The URL to open (e.g., https://example.com)"),
                    ])
                ]),
                "required": .array([.string("url")]),
            ],
            handler: { args in
                let ctx = registry.resolve(args["target"]?.asString())
                guard let ctx else { return .error("Unknown target '\(args["target"]?.asString() ?? "")'") }
                let input = ctx.input

                guard let url = args["url"]?.asString() else {
                    return .error("Missing required parameter: url (string)")
                }

                if let error = input.openURL(url) {
                    return .error(error)
                }
                return .text("Opened URL: \(url)")
            }
        ))

        // press_home — navigate to iPhone home screen
        server.registerTool(MCPToolDefinition(
            name: "press_home",
            description: """
                Press the Home button on the mirrored iPhone, returning to the home screen. \
                Equivalent to swiping up from the bottom on a Face ID device.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { args in
                let ctx = registry.resolve(args["target"]?.asString())
                guard let ctx else { return .error("Unknown target '\(args["target"]?.asString() ?? "")'") }
                guard let menuBridge = ctx.bridge as? (any MenuActionCapable) else {
                    return .error("Target '\(ctx.name)' does not support press_home")
                }

                if menuBridge.triggerMenuAction(menu: "View", item: "Home Screen") {
                    return .text("Pressed Home — navigated to home screen")
                } else {
                    return .error("Failed to press Home. Is iPhone Mirroring running?")
                }
            }
        ))

        // press_app_switcher — open the iPhone app switcher
        server.registerTool(MCPToolDefinition(
            name: "press_app_switcher",
            description: """
                Open the App Switcher on the mirrored iPhone, showing recently used apps. \
                From here you can swipe between apps or swipe up to close them.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { args in
                let ctx = registry.resolve(args["target"]?.asString())
                guard let ctx else { return .error("Unknown target '\(args["target"]?.asString() ?? "")'") }
                guard let menuBridge = ctx.bridge as? (any MenuActionCapable) else {
                    return .error("Target '\(ctx.name)' does not support press_app_switcher")
                }

                if menuBridge.triggerMenuAction(menu: "View", item: "App Switcher") {
                    return .text("Opened App Switcher")
                } else {
                    return .error("Failed to open App Switcher. Is iPhone Mirroring running?")
                }
            }
        ))

        // spotlight — open iPhone Spotlight search
        server.registerTool(MCPToolDefinition(
            name: "spotlight",
            description: """
                Open Spotlight search on the mirrored iPhone. \
                After opening, use type_text to enter a search query.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { args in
                let ctx = registry.resolve(args["target"]?.asString())
                guard let ctx else { return .error("Unknown target '\(args["target"]?.asString() ?? "")'") }
                guard let menuBridge = ctx.bridge as? (any MenuActionCapable) else {
                    return .error("Target '\(ctx.name)' does not support spotlight")
                }

                if menuBridge.triggerMenuAction(menu: "View", item: "Spotlight") {
                    return .text("Opened Spotlight search")
                } else {
                    return .error("Failed to open Spotlight. Is iPhone Mirroring running?")
                }
            }
        ))
    }
}
