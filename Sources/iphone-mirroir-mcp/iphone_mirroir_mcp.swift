// ABOUTME: Entry point for the iPhone Mirroring MCP server.
// ABOUTME: Registers all MCP tools and starts the JSON-RPC server loop over stdio.

import Foundation

@main
struct IPhoneMirroirMCP {
    static func main() {
        // Redirect stderr for logging (stdout is reserved for MCP JSON-RPC)
        let bridge = MirroringBridge()
        let capture = ScreenCapture(bridge: bridge)
        let input = InputSimulation(bridge: bridge)
        let server = MCPServer()

        registerTools(server: server, bridge: bridge, capture: capture, input: input)

        // Start the MCP server loop
        server.run()
    }

    static func registerTools(
        server: MCPServer,
        bridge: MirroringBridge,
        capture: ScreenCapture,
        input: InputSimulation
    ) {
        // screenshot — capture the mirroring window
        server.registerTool(MCPToolDefinition(
            name: "screenshot",
            description: """
                Capture a screenshot of the iPhone Mirroring window. \
                Returns the current screen content as a PNG image. \
                Use this to see what is displayed on the mirrored iPhone.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { _ in
                guard bridge.findProcess() != nil else {
                    return .error("iPhone Mirroring app is not running")
                }

                let state = bridge.getState()
                if state == .paused {
                    _ = bridge.pressResume()
                    usleep(2_000_000) // Wait 2s for connection to resume
                }

                guard let base64 = capture.captureBase64() else {
                    return .error(
                        "Failed to capture screenshot. Is iPhone Mirroring window visible?")
                }

                return .image(base64)
            }
        ))

        // tap — click at coordinates on the mirrored iPhone
        server.registerTool(MCPToolDefinition(
            name: "tap",
            description: """
                Tap at a specific position on the mirrored iPhone screen. \
                Coordinates are relative to the iPhone Mirroring window \
                (0,0 is top-left of the mirrored content). \
                Use screenshot first to identify element positions.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "x": .object([
                        "type": .string("number"),
                        "description": .string(
                            "X coordinate relative to the mirroring window (0 = left edge)"),
                    ]),
                    "y": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Y coordinate relative to the mirroring window (0 = top edge)"),
                    ]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ],
            handler: { args in
                guard let x = args["x"]?.asNumber(), let y = args["y"]?.asNumber() else {
                    return .error("Missing required parameters: x, y (numbers)")
                }

                if input.tap(x: x, y: y) {
                    return .text("Tapped at (\(Int(x)), \(Int(y)))")
                } else {
                    return .error(
                        "Failed to tap. Is iPhone Mirroring running and window visible?")
                }
            }
        ))

        // swipe — drag gesture on the mirrored iPhone
        server.registerTool(MCPToolDefinition(
            name: "swipe",
            description: """
                Perform a swipe gesture on the mirrored iPhone screen. \
                Coordinates are relative to the iPhone Mirroring window. \
                Common gestures: swipe up (scroll down), swipe down (scroll up), \
                swipe left/right for navigation.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "from_x": .object([
                        "type": .string("number"),
                        "description": .string("Start X coordinate"),
                    ]),
                    "from_y": .object([
                        "type": .string("number"),
                        "description": .string("Start Y coordinate"),
                    ]),
                    "to_x": .object([
                        "type": .string("number"),
                        "description": .string("End X coordinate"),
                    ]),
                    "to_y": .object([
                        "type": .string("number"),
                        "description": .string("End Y coordinate"),
                    ]),
                    "duration_ms": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Duration of swipe in milliseconds (default: 300)"),
                    ]),
                ]),
                "required": .array([
                    .string("from_x"), .string("from_y"),
                    .string("to_x"), .string("to_y"),
                ]),
            ],
            handler: { args in
                guard let fromX = args["from_x"]?.asNumber(),
                    let fromY = args["from_y"]?.asNumber(),
                    let toX = args["to_x"]?.asNumber(),
                    let toY = args["to_y"]?.asNumber()
                else {
                    return .error(
                        "Missing required parameters: from_x, from_y, to_x, to_y (numbers)")
                }

                let duration = args["duration_ms"]?.asInt() ?? 300

                if input.swipe(
                    fromX: fromX, fromY: fromY,
                    toX: toX, toY: toY,
                    durationMs: duration
                ) {
                    return .text(
                        "Swiped from (\(Int(fromX)),\(Int(fromY))) to (\(Int(toX)),\(Int(toY)))"
                    )
                } else {
                    return .error(
                        "Failed to swipe. Is iPhone Mirroring running and window visible?")
                }
            }
        ))

        // type_text — send keyboard input
        server.registerTool(MCPToolDefinition(
            name: "type_text",
            description: """
                Type text on the mirrored iPhone. The iPhone Mirroring window \
                must be focused and a text field must be active on the iPhone. \
                Sends each character as a keyboard event.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("The text to type"),
                    ])
                ]),
                "required": .array([.string("text")]),
            ],
            handler: { args in
                guard let text = args["text"]?.asString() else {
                    return .error("Missing required parameter: text (string)")
                }

                if input.typeText(text) {
                    return .text("Typed \(text.count) characters")
                } else {
                    return .error(
                        "Failed to type text. Is iPhone Mirroring running and focused?")
                }
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
            handler: { _ in
                bridge.activate()
                if bridge.triggerMenuAction(menu: "View", item: "Home Screen") {
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
            handler: { _ in
                bridge.activate()
                if bridge.triggerMenuAction(menu: "View", item: "App Switcher") {
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
            handler: { _ in
                bridge.activate()
                if bridge.triggerMenuAction(menu: "View", item: "Spotlight") {
                    return .text("Opened Spotlight search")
                } else {
                    return .error("Failed to open Spotlight. Is iPhone Mirroring running?")
                }
            }
        ))

        // status — get the current mirroring connection state
        server.registerTool(MCPToolDefinition(
            name: "status",
            description: """
                Get the current status of the iPhone Mirroring connection and Karabiner helper. \
                Returns whether the app is running, connected, paused, or has no window. \
                Also reports whether the Karabiner helper daemon is available for input.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { _ in
                let state = bridge.getState()
                let mirroringStatus: String
                switch state {
                case .connected:
                    let info = bridge.getWindowInfo()
                    let sizeDesc =
                        info.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "unknown"
                    mirroringStatus = "Connected — mirroring active (window: \(sizeDesc))"
                case .paused:
                    mirroringStatus = "Paused — connection paused, can resume"
                case .notRunning:
                    mirroringStatus = "Not running — iPhone Mirroring app is not open"
                case .noWindow:
                    mirroringStatus = "No window — app is running but no mirroring window found"
                }

                // Check Karabiner helper status
                let helperStatus: String
                if let status = input.helperClient.status() {
                    let kb = status["keyboard_ready"] as? Bool ?? false
                    let pt = status["pointing_ready"] as? Bool ?? false
                    helperStatus = "Helper: connected (keyboard=\(kb), pointing=\(pt))"
                } else {
                    helperStatus = "Helper: not running (tap/type/swipe use CGEvent fallback)"
                }

                return .text("\(mirroringStatus)\n\(helperStatus)")
            }
        ))
    }
}

// MARK: - JSONValue convenience extensions

extension JSONValue {
    func asString() -> String? {
        if case .string(let s) = self { return s }
        return nil
    }

    func asNumber() -> Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    func asInt() -> Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }
}
