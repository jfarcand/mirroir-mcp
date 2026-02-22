// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers input-related MCP tools: tap, swipe, drag, type_text, press_key, long_press, double_tap, shake.
// ABOUTME: Each tool maps MCP JSON-RPC calls to the InputSimulation subsystem via Karabiner HID.

import Foundation
import HelperLib

extension MirroirMCP {
    /// Schema fragment for the optional cursor_mode parameter on coordinate tools.
    private static let cursorModeSchema: JSONValue = .object([
        "type": .string("string"),
        "enum": .array([.string("direct"), .string("preserving")]),
        "description": .string(
            "Cursor management: 'direct' leaves cursor at target, "
            + "'preserving' restores cursor to its original position after the operation. "
            + "Defaults to 'direct' for iPhone Mirroring, 'preserving' for generic windows."),
    ])

    /// Result of parsing cursor_mode: a valid mode (or nil for default) vs an error message.
    private enum CursorModeResult {
        case ok(CursorMode?)
        case invalid(String)
    }

    /// Parse an optional cursor_mode string from tool args into a CursorMode.
    /// Returns `.ok(nil)` when absent, `.ok(mode)` for valid values,
    /// or `.invalid(message)` for unrecognized values.
    private static func parseCursorMode(_ args: [String: JSONValue]) -> CursorModeResult {
        guard let value = args["cursor_mode"]?.asString() else { return .ok(nil) }
        switch value {
        case "direct": return .ok(.direct)
        case "preserving": return .ok(.preserving)
        default:
            return .invalid("Invalid cursor_mode '\(value)'. Must be 'direct' or 'preserving'.")
        }
    }

    static func registerInputTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
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
                    "cursor_mode": cursorModeSchema,
                ]),
                "required": .array([.string("x"), .string("y")]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let input = ctx.input

                guard let x = args["x"]?.asNumber(), let y = args["y"]?.asNumber() else {
                    return .error("Missing required parameters: x, y (numbers)")
                }

                let cursorMode: CursorMode?
                switch parseCursorMode(args) {
                case .ok(let mode): cursorMode = mode
                case .invalid(let msg): return .error(msg)
                }

                if let error = input.tap(x: x, y: y, cursorMode: cursorMode) {
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
                    "cursor_mode": cursorModeSchema,
                ]),
                "required": .array([
                    .string("from_x"), .string("from_y"),
                    .string("to_x"), .string("to_y"),
                ]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let input = ctx.input

                guard let fromX = args["from_x"]?.asNumber(),
                    let fromY = args["from_y"]?.asNumber(),
                    let toX = args["to_x"]?.asNumber(),
                    let toY = args["to_y"]?.asNumber()
                else {
                    return .error(
                        "Missing required parameters: from_x, from_y, to_x, to_y (numbers)")
                }

                let duration = args["duration_ms"]?.asInt() ?? EnvConfig.defaultSwipeDurationMs

                let cursorMode: CursorMode?
                switch parseCursorMode(args) {
                case .ok(let mode): cursorMode = mode
                case .invalid(let msg): return .error(msg)
                }

                if let error = input.swipe(
                    fromX: fromX, fromY: fromY,
                    toX: toX, toY: toY,
                    durationMs: duration,
                    cursorMode: cursorMode
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
                    "cursor_mode": cursorModeSchema,
                ]),
                "required": .array([
                    .string("from_x"), .string("from_y"),
                    .string("to_x"), .string("to_y"),
                ]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let input = ctx.input

                guard let fromX = args["from_x"]?.asNumber(),
                    let fromY = args["from_y"]?.asNumber(),
                    let toX = args["to_x"]?.asNumber(),
                    let toY = args["to_y"]?.asNumber()
                else {
                    return .error(
                        "Missing required parameters: from_x, from_y, to_x, to_y (numbers)")
                }

                let duration = args["duration_ms"]?.asInt() ?? EnvConfig.defaultDragDurationMs

                let cursorMode: CursorMode?
                switch parseCursorMode(args) {
                case .ok(let mode): cursorMode = mode
                case .invalid(let msg): return .error(msg)
                }

                if let error = input.drag(
                    fromX: fromX, fromY: fromY,
                    toX: toX, toY: toY,
                    durationMs: duration,
                    cursorMode: cursorMode
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
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let input = ctx.input

                guard let text = args["text"]?.asString() else {
                    return .error("Missing required parameter: text (string)")
                }

                let result = input.typeText(text)
                guard result.success else {
                    return .error(result.error ?? "Failed to type text")
                }

                if let warning = result.warning {
                    return .text("Typed \(text.count) characters. Warning: \(warning)")
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
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let input = ctx.input

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
                    "cursor_mode": cursorModeSchema,
                ]),
                "required": .array([.string("x"), .string("y")]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let input = ctx.input

                guard let x = args["x"]?.asNumber(), let y = args["y"]?.asNumber() else {
                    return .error("Missing required parameters: x, y (numbers)")
                }

                let duration = args["duration_ms"]?.asInt() ?? EnvConfig.defaultLongPressDurationMs

                let cursorMode: CursorMode?
                switch parseCursorMode(args) {
                case .ok(let mode): cursorMode = mode
                case .invalid(let msg): return .error(msg)
                }

                if let error = input.longPress(x: x, y: y, durationMs: duration,
                                               cursorMode: cursorMode) {
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
                    "cursor_mode": cursorModeSchema,
                ]),
                "required": .array([.string("x"), .string("y")]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let input = ctx.input

                guard let x = args["x"]?.asNumber(), let y = args["y"]?.asNumber() else {
                    return .error("Missing required parameters: x, y (numbers)")
                }

                let cursorMode: CursorMode?
                switch parseCursorMode(args) {
                case .ok(let mode): cursorMode = mode
                case .invalid(let msg): return .error(msg)
                }

                if let error = input.doubleTap(x: x, y: y, cursorMode: cursorMode) {
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
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let input = ctx.input

                let result = input.shake()
                guard result.success else {
                    return .error(result.error ?? "Failed to trigger shake")
                }
                return .text("Triggered shake gesture (Ctrl+Cmd+Z)")
            }
        ))
    }
}
