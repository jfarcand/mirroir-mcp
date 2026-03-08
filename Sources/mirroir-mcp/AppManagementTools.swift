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
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                guard let menuBridge = ctx.bridge as? (any MenuActionCapable) else {
                    return .error("Target '\(ctx.name)' does not support reset_app")
                }
                let input = ctx.input

                guard let appName = args["name"]?.asString() else {
                    return .error("Missing required parameter: name (string)")
                }

                // Launch the app via Spotlight. This handles localization: typing
                // "Settings" finds "Réglages" on a French iPhone, for example.
                if let error = input.launchApp(name: appName) {
                    return .error("Failed to launch '\(appName)': \(error)")
                }
                usleep(EnvConfig.toolSettlingDelayUs)

                // Open the App Switcher. The just-launched app is guaranteed
                // to be the centered (most-recently-used) card.
                guard menuBridge.triggerMenuAction(menu: "View", item: "App Switcher") else {
                    _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
                    return .error("Failed to open App Switcher. Is '\(ctx.name)' running?")
                }
                usleep(EnvConfig.toolSettlingDelayUs)

                // Verify the target app is actually visible in the App Switcher
                // before swiping. If the Spotlight launch failed or the app wasn't
                // found, the centered card belongs to a different app — don't kill it.
                let describer = ctx.describer
                let windowSize = ctx.bridge.getWindowInfo()?.size
                guard let ocrResult = describer.describe(skipOCR: false) else {
                    _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
                    return .error("Failed to capture App Switcher screen for verification")
                }
                let visibleTexts = ocrResult.elements.map { $0.text.lowercased() }
                let appNameLower = appName.lowercased()
                let appFound = visibleTexts.contains { $0.contains(appNameLower) }
                if !appFound {
                    _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
                    return .text("'\(appName)' is not in the App Switcher (already quit)")
                }

                // Drag up on the centered card to dismiss it.
                let cardX = (windowSize.map { Double($0.width) } ?? 410.0) * EnvConfig.appSwitcherCardXFraction
                let cardY = (windowSize.map { Double($0.height) } ?? 890.0) * EnvConfig.appSwitcherCardYFraction
                let toY = max(0, cardY - EnvConfig.appSwitcherSwipeDistance)
                if let error = input.drag(fromX: cardX, fromY: cardY,
                                           toX: cardX, toY: toY,
                                           durationMs: EnvConfig.appSwitcherSwipeDurationMs) {
                    _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
                    return .error("Failed to swipe app card: \(error)")
                }

                usleep(EnvConfig.toolSettlingDelayUs)

                // Return to home screen
                _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")

                return .text("Force-quit '\(appName)'")
            }
        ))
    }
}
