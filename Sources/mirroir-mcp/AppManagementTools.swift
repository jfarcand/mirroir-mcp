// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the reset_app MCP tool for force-quitting apps via the App Switcher.
// ABOUTME: Uses menu actions to open App Switcher, OCR to find the app, and swipe up to dismiss.

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
                let describer = ctx.describer

                guard let appName = args["name"]?.asString() else {
                    return .error("Missing required parameter: name (string)")
                }

                // Open App Switcher
                guard menuBridge.triggerMenuAction(menu: "View", item: "App Switcher") else {
                    return .error("Failed to open App Switcher. Is '\(ctx.name)' running?")
                }

                usleep(EnvConfig.toolSettlingDelayUs)

                // Swipe left through the App Switcher carousel to find the app card.
                // Only 2-3 cards are visible at a time; off-screen labels are clipped.
                let maxSwipes = EnvConfig.appSwitcherMaxSwipes
                var match: ElementMatcher.MatchResult?

                for attempt in 0...maxSwipes {
                    guard let describeResult = describer.describe(skipOCR: false) else {
                        _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
                        return .error("Failed to capture screen in App Switcher")
                    }

                    if let found = ElementMatcher.findMatch(label: appName,
                                                            in: describeResult.elements) {
                        match = found
                        break
                    }

                    // Swipe left to reveal more cards
                    if attempt < maxSwipes {
                        _ = input.swipe(fromX: 300, fromY: 400,
                                        toX: 100, toY: 400,
                                        durationMs: EnvConfig.defaultSwipeDurationMs)
                        usleep(EnvConfig.toolSettlingDelayUs)
                    }
                }

                guard let match else {
                    _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
                    return .text("'\(appName)' not in App Switcher (already quit)")
                }

                // Drag up on the app card to force-quit.
                // Uses drag (touch events) instead of swipe (scroll wheel) because
                // scroll wheel events are misinterpreted after horizontal carousel navigation.
                // OCR finds the app name label above the card preview, so offset
                // downward into the card body before dragging, and clamp toY >= 0.
                let cardX = match.element.tapX
                let cardY = match.element.tapY + EnvConfig.appSwitcherCardOffset
                let toY = max(0, cardY - EnvConfig.appSwitcherSwipeDistance)
                if let error = input.drag(fromX: cardX, fromY: cardY,
                                           toX: cardX, toY: toY, durationMs: EnvConfig.appSwitcherSwipeDurationMs) {
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
