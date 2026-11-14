// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers navigation-related MCP tools: launch_app, open_url, press_home, press_app_switcher, press_back, spotlight.
// ABOUTME: Each tool maps MCP JSON-RPC calls to the bridge and input subsystems for app navigation.

import Foundation
import HelperLib

extension MirroirMCP {
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
                Opens Spotlight, types the app name, confirms by OCR that the name \
                appeared, and opens the top result only when it is an app, tapping its \
                tile; with no app behind the name (not installed) it fails without \
                opening anything. If Spotlight never shows the typed name (on iOS 26 \
                it can take typing only once per iPhone Mirroring session), it closes \
                Spotlight and opens the app from the Home Screen icon whose label is \
                exactly the name on the page Home shows; other pages, folders, the Dock \
                and the App Library are not searched. The app name should match the display \
                name shown on the iPhone home screen.
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
                let (ctx, err) = registry.resolveForTool(args, requiring: .launchApp)
                guard let ctx else { return err! }
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
                return LaunchAppConfirmation.outcome(
                    appName: appName, describer: ctx.ocrDescriber,
                    windowHeight: ctx.bridge.getWindowInfo().map { Double($0.size.height) }
                )
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
                let (ctx, err) = registry.resolveForTool(args, requiring: .openURL)
                guard let ctx else { return err! }
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
                Equivalent to swiping up from the bottom on a Face ID device. Home is \
                pressed again when it brings back Spotlight (iOS does after an app \
                opened from it) or leaves the screen unchanged.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args, requiring: .pressHome)
                guard let ctx else { return err! }
                let outcome = MirroringMenuCommand.pressHome(
                    bridge: ctx.bridge, input: ctx.input, describer: ctx.describer)
                if case .failed = outcome { return .error(outcome.report) }
                return .text(outcome.report)
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
                let (ctx, err) = registry.resolveForTool(args, requiring: .pressAppSwitcher)
                guard let ctx else { return err! }
                if let error = MirroringMenuCommand.appSwitcher.press(bridge: ctx.bridge, input: ctx.input) {
                    return .error(error)
                }
                return .text("Opened App Switcher")
            }
        ))

        // press_back — go back one screen with the target's backtracker
        server.registerTool(MCPToolDefinition(
            name: "press_back",
            description: """
                Navigate back one screen. On the mirrored iPhone it taps the "<" \
                back chevron OCR finds in the top navigation bar, or the usual \
                back-button point when OCR finds none; iOS apps do not implement \
                Cmd+[ (the key arrives and nothing handles it), so a tap is the \
                way back. On a macOS app target it presses Cmd+[. The reply says \
                which was done and whether the screen changed; a press that left \
                the screen unchanged is an error.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                return BackNavigation.pressBack(ctx)
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
                let (ctx, err) = registry.resolveForTool(args, requiring: .spotlight)
                guard let ctx else { return err! }
                if let error = MirroringMenuCommand.spotlight.press(bridge: ctx.bridge, input: ctx.input) {
                    return .error(error)
                }
                return .text("Opened Spotlight search")
            }
        ))
    }
}
