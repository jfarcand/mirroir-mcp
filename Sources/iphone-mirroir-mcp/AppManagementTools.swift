// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the reset_app MCP tool for force-quitting apps via the App Switcher.
// ABOUTME: Uses menu actions to open App Switcher, OCR to find the app, and swipe up to dismiss.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
    static func registerAppManagementTools(
        server: MCPServer,
        bridge: any MirroringBridging,
        input: any InputProviding,
        describer: any ScreenDescribing
    ) {
        // reset_app — force-quit an app via the App Switcher
        server.registerTool(MCPToolDefinition(
            name: "reset_app",
            description: """
                Force-quit an app on the mirrored iPhone by opening the App Switcher, \
                finding the app card by name via OCR, and swiping it up to dismiss. \
                If the app is not in the App Switcher, it is treated as already quit. \
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
                guard let appName = args["name"]?.asString() else {
                    return .error("Missing required parameter: name (string)")
                }

                // Open App Switcher
                guard bridge.triggerMenuAction(menu: "View", item: "App Switcher") else {
                    return .error("Failed to open App Switcher. Is iPhone Mirroring running?")
                }

                usleep(EnvConfig.toolSettlingDelayUs)

                // OCR to find the app card
                guard let describeResult = describer.describe(skipOCR: false) else {
                    _ = bridge.triggerMenuAction(menu: "View", item: "Home Screen")
                    return .error("Failed to capture screen in App Switcher")
                }

                guard let match = ElementMatcher.findMatch(label: appName,
                                                             in: describeResult.elements) else {
                    _ = bridge.triggerMenuAction(menu: "View", item: "Home Screen")
                    return .text("'\(appName)' not in App Switcher (already quit)")
                }

                // Swipe up on the app card to force-quit
                let cardX = match.element.tapX
                let cardY = match.element.tapY
                if let error = input.swipe(fromX: cardX, fromY: cardY,
                                            toX: cardX, toY: cardY - EnvConfig.appSwitcherSwipeDistance, durationMs: EnvConfig.appSwitcherSwipeDurationMs) {
                    _ = bridge.triggerMenuAction(menu: "View", item: "Home Screen")
                    return .error("Failed to swipe app card: \(error)")
                }

                usleep(EnvConfig.toolSettlingDelayUs)

                // Return to home screen
                _ = bridge.triggerMenuAction(menu: "View", item: "Home Screen")

                return .text("Force-quit '\(appName)'")
            }
        ))
    }
}
