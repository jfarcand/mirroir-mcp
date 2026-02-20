// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the set_network MCP tool for toggling network settings on iPhone.
// ABOUTME: Navigates to iOS Settings to toggle Airplane, Wi-Fi, or Cellular modes.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
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
                        "enum": .array([
                            .string("airplane_on"), .string("airplane_off"),
                            .string("wifi_on"), .string("wifi_off"),
                            .string("cellular_on"), .string("cellular_off"),
                        ]),
                        "description": .string(
                            "Network mode to set: airplane_on/off, wifi_on/off, cellular_on/off"),
                    ])
                ]),
                "required": .array([.string("mode")]),
            ],
            handler: { args in
                let ctx = registry.resolve(args["target"]?.asString())
                guard let ctx else { return .error("Unknown target '\(args["target"]?.asString() ?? "")'") }
                guard let menuBridge = ctx.bridge as? (any MenuActionCapable) else {
                    return .error("Target '\(ctx.name)' does not support set_network")
                }
                let input = ctx.input
                let describer = ctx.describer

                guard let mode = args["mode"]?.asString() else {
                    return .error("Missing required parameter: mode (string)")
                }

                let validModes = ["airplane_on", "airplane_off", "wifi_on", "wifi_off",
                                  "cellular_on", "cellular_off"]
                guard validModes.contains(mode) else {
                    return .error(
                        "Unknown mode: \(mode). Use: \(validModes.joined(separator: ", "))")
                }

                // Launch Settings
                if let error = input.launchApp(name: "Settings") {
                    return .error("Failed to launch Settings: \(error)")
                }
                usleep(EnvConfig.settingsLoadUs)  // Wait for Settings to load

                let targetLabel: String
                switch mode {
                case "airplane_on", "airplane_off":
                    targetLabel = "Airplane"
                case "wifi_on", "wifi_off":
                    targetLabel = "Wi-Fi"
                case "cellular_on", "cellular_off":
                    targetLabel = "Cellular"
                default:
                    targetLabel = ""
                }

                // Find and tap the setting row
                guard let describeResult = describer.describe(skipOCR: false) else {
                    _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
                    return .error("Failed to capture Settings screen")
                }

                guard let match = ElementMatcher.findMatch(label: targetLabel,
                                                             in: describeResult.elements) else {
                    _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
                    return .error("'\(targetLabel)' not found in Settings")
                }

                if let error = input.tap(x: match.element.tapX, y: match.element.tapY) {
                    _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
                    return .error("Failed to tap \(targetLabel): \(error)")
                }

                usleep(EnvConfig.toolSettlingDelayUs)

                // Return to home screen
                _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")

                return .text("Toggled \(mode)")
            }
        ))
    }
}
