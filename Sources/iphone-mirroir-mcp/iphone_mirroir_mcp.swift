// Copyright 2026 jfarcand
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Entry point for the iPhone Mirroring MCP server.
// ABOUTME: Registers all MCP tools and starts the JSON-RPC server loop over stdio.

import Darwin
import Foundation

@main
struct IPhoneMirroirMCP {
    static func main() {
        // Ignore SIGPIPE so the server doesn't crash when the MCP client
        // disconnects or its stdio pipe closes unexpectedly.
        signal(SIGPIPE, SIG_IGN)

        // Redirect stderr for logging (stdout is reserved for MCP JSON-RPC)
        let bridge = MirroringBridge()
        let capture = ScreenCapture(bridge: bridge)
        let recorder = ScreenRecorder(bridge: bridge)
        let input = InputSimulation(bridge: bridge)
        let describer = ScreenDescriber(bridge: bridge)
        let server = MCPServer()

        registerTools(server: server, bridge: bridge, capture: capture,
                      recorder: recorder, input: input, describer: describer)

        // Start the MCP server loop
        server.run()
    }

    static func registerTools(
        server: MCPServer,
        bridge: MirroringBridge,
        capture: ScreenCapture,
        recorder: ScreenRecorder,
        input: InputSimulation,
        describer: ScreenDescriber
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

        // describe_screen — OCR-based screen element detection with tap coordinates
        server.registerTool(MCPToolDefinition(
            name: "describe_screen",
            description: """
                Analyze the iPhone screen using OCR and return all visible text elements \
                with their exact tap coordinates. Use this instead of visually estimating \
                positions from screenshots. Returns both a structured text list of elements \
                and the screenshot image. Coordinates are in the same point system as the \
                tap tool (0,0 = top-left of mirroring window).
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
                    usleep(2_000_000)
                }
                guard let result = describer.describe() else {
                    return .error(
                        "Failed to capture/analyze screen. Is iPhone Mirroring window visible?")
                }

                var lines = ["Screen elements (tap coordinates in points):"]
                for el in result.elements.sorted(by: { $0.tapY < $1.tapY }) {
                    lines.append("- \"\(el.text)\" at (\(Int(el.tapX)), \(Int(el.tapY)))")
                }
                if result.elements.isEmpty {
                    lines.append("(no text detected)")
                }
                let description = lines.joined(separator: "\n")

                return MCPToolResult(
                    content: [
                        .text(description),
                        .image(result.screenshotBase64, mimeType: "image/png"),
                    ],
                    isError: false
                )
            }
        ))

        // start_recording — begin video recording of the mirroring window
        server.registerTool(MCPToolDefinition(
            name: "start_recording",
            description: """
                Start recording a video of the mirrored iPhone screen. \
                Records the iPhone Mirroring window as a .mov file. \
                Use stop_recording to end the recording and get the file path. \
                Requires Screen Recording permission in System Preferences.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "output_path": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional file path for the recording (default: temp directory)"),
                    ])
                ]),
            ],
            handler: { args in
                let outputPath = args["output_path"]?.asString()

                if let error = recorder.startRecording(outputPath: outputPath) {
                    return .error(error)
                }
                return .text("Recording started")
            }
        ))

        // stop_recording — stop video recording and return the file path
        server.registerTool(MCPToolDefinition(
            name: "stop_recording",
            description: """
                Stop the current video recording and return the file path. \
                Must be called after start_recording. Returns the path to \
                the recorded .mov file.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { _ in
                let result = recorder.stopRecording()
                if let error = result.error {
                    return .error(error)
                }
                guard let path = result.filePath else {
                    return .error("Recording stopped but no file was produced")
                }
                return .text("Recording saved to: \(path)")
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

                if let error = input.tap(x: x, y: y) {
                    return .error(error)
                }
                return .text("Tapped at (\(Int(x)), \(Int(y)))")
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

                if let error = input.swipe(
                    fromX: fromX, fromY: fromY,
                    toX: toX, toY: toY,
                    durationMs: duration
                ) {
                    return .error(error)
                }
                return .text(
                    "Swiped from (\(Int(fromX)),\(Int(fromY))) to (\(Int(toX)),\(Int(toY)))"
                )
            }
        ))

        // drag — slow deliberate drag from point A to point B
        server.registerTool(MCPToolDefinition(
            name: "drag",
            description: """
                Drag from one point to another on the mirrored iPhone screen \
                with sustained contact. Unlike swipe (quick flick), drag is a \
                slow deliberate movement for rearranging icons, adjusting sliders, \
                and drag-and-drop operations. Coordinates are relative to the \
                iPhone Mirroring window.
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
                            "Duration of drag in milliseconds (default: 1000, minimum: 200)"),
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

                let duration = args["duration_ms"]?.asInt() ?? 1000

                if let error = input.drag(
                    fromX: fromX, fromY: fromY,
                    toX: toX, toY: toY,
                    durationMs: duration
                ) {
                    return .error(error)
                }
                return .text(
                    "Dragged from (\(Int(fromX)),\(Int(fromY))) to (\(Int(toX)),\(Int(toY))) over \(duration)ms"
                )
            }
        ))

        // type_text — type text via Karabiner HID with layout translation
        server.registerTool(MCPToolDefinition(
            name: "type_text",
            description: """
                Type text on the mirrored iPhone. Automatically activates the \
                iPhone Mirroring window if needed (one-time Space switch). \
                A text field must be active on the iPhone. \
                Sends keystrokes through the Karabiner virtual HID keyboard \
                with automatic keyboard layout translation for non-US layouts.
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

                let result = input.typeText(text)
                guard result.success else {
                    return .error(result.error ?? "Failed to type text")
                }

                return .text("Typed \(text.count) characters")
            }
        ))

        // press_key — send a special key press with optional modifiers
        server.registerTool(MCPToolDefinition(
            name: "press_key",
            description: """
                Send a key press to the mirrored iPhone with optional modifiers. \
                Automatically activates the iPhone Mirroring window if needed (one-time Space switch). \
                Supported keys: return, escape, tab, delete, space, up, down, left, right, \
                or any single character (a-z, 0-9, etc.) for shortcuts. \
                Optional modifiers: command, shift, option, control. \
                Examples: press Return to confirm, Escape to cancel, Cmd+L for address bar.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "key": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Key name: return, escape, tab, delete, space, up, down, left, right, or a single character"),
                    ]),
                    "modifiers": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                        ]),
                        "description": .string(
                            "Optional modifier keys: command, shift, option, control"),
                    ]),
                ]),
                "required": .array([.string("key")]),
            ],
            handler: { args in
                guard let keyName = args["key"]?.asString() else {
                    return .error("Missing required parameter: key (string)")
                }

                let modifiers = args["modifiers"]?.asStringArray() ?? []

                let result = input.pressKey(
                    keyName: keyName, modifiers: modifiers
                )
                guard result.success else {
                    return .error(result.error ?? "Failed to press key")
                }

                if modifiers.isEmpty {
                    return .text("Pressed \(keyName)")
                }
                return .text("Pressed \(modifiers.joined(separator: "+"))+\(keyName)")
            }
        ))

        // long_press — hold tap at coordinates for a configurable duration
        server.registerTool(MCPToolDefinition(
            name: "long_press",
            description: """
                Long press at a specific position on the mirrored iPhone screen. \
                Holds the tap for a configurable duration (default 500ms). \
                Use for context menus, drag initiation, and any gesture that \
                requires holding a touch. Coordinates are relative to the \
                iPhone Mirroring window.
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
                    "duration_ms": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Hold duration in milliseconds (default: 500, minimum: 100)"),
                    ]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ],
            handler: { args in
                guard let x = args["x"]?.asNumber(), let y = args["y"]?.asNumber() else {
                    return .error("Missing required parameters: x, y (numbers)")
                }

                let duration = args["duration_ms"]?.asInt() ?? 500

                if let error = input.longPress(x: x, y: y, durationMs: duration) {
                    return .error(error)
                }
                return .text("Long pressed at (\(Int(x)), \(Int(y))) for \(duration)ms")
            }
        ))

        // double_tap — two rapid taps at coordinates
        server.registerTool(MCPToolDefinition(
            name: "double_tap",
            description: """
                Double-tap at a specific position on the mirrored iPhone screen. \
                Performs two rapid taps for gestures like zoom, text selection, \
                and widget activation. Coordinates are relative to the \
                iPhone Mirroring window.
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

                if let error = input.doubleTap(x: x, y: y) {
                    return .error(error)
                }
                return .text("Double-tapped at (\(Int(x)), \(Int(y)))")
            }
        ))

        // shake — trigger a device shake gesture
        server.registerTool(MCPToolDefinition(
            name: "shake",
            description: """
                Trigger a shake gesture on the mirrored iPhone. \
                Sends Ctrl+Cmd+Z which triggers shake-to-undo in iOS apps. \
                Useful for: Expo Go developer menu, React Native debug menu, \
                undo actions, and any app that responds to device shake.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { _ in
                let result = input.shake()
                guard result.success else {
                    return .error(result.error ?? "Failed to trigger shake")
                }
                return .text("Triggered shake gesture (Ctrl+Cmd+Z)")
            }
        ))

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
                guard let appName = args["name"]?.asString() else {
                    return .error("Missing required parameter: name (string)")
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
            handler: { _ in
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
                if bridge.triggerMenuAction(menu: "View", item: "Spotlight") {
                    return .text("Opened Spotlight search")
                } else {
                    return .error("Failed to open Spotlight. Is iPhone Mirroring running?")
                }
            }
        ))

        // get_orientation — report device orientation
        server.registerTool(MCPToolDefinition(
            name: "get_orientation",
            description: """
                Get the current device orientation of the mirrored iPhone. \
                Returns "portrait" or "landscape" based on the mirroring \
                window dimensions. Useful for adapting touch coordinates \
                and understanding the current screen layout.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { _ in
                guard let orientation = bridge.getOrientation() else {
                    return .error(
                        "Cannot determine orientation. Is iPhone Mirroring running?")
                }

                let info = bridge.getWindowInfo()
                let sizeDesc = info.map {
                    "\(Int($0.size.width))x\(Int($0.size.height))"
                } ?? "unknown"

                return .text(
                    "Orientation: \(orientation.rawValue) (window: \(sizeDesc))")
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
                    let posDesc =
                        info.map { "pos=(\(Int($0.position.x)),\(Int($0.position.y)))" } ?? "pos=unknown"
                    let orientDesc = bridge.getOrientation()?.rawValue ?? "unknown"
                    mirroringStatus = "Connected — mirroring active (window: \(sizeDesc), \(posDesc), \(orientDesc))"
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
                    helperStatus = "Helper: not running (tap/type/swipe unavailable)"
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

    func asStringArray() -> [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap { $0.asString() }
    }
}
