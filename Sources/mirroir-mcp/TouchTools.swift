// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the touch MCP tool: one persistent touch contact held across calls.
// ABOUTME: Parses begin/move/end/cancel arguments and delegates to InputProviding.touch.

import Foundation
import HelperLib

extension MirroirMCP {

    /// Names of the touch tool's `action` argument, in schema order.
    private static let touchActions = ["begin", "move", "end", "cancel"]

    static func registerTouchTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        server.registerTool(MCPToolDefinition(
            name: "touch",
            description: """
                Hold one finger on the mirrored iPhone across calls. \
                action "begin" presses at (x, y) and keeps it down; "move" slides \
                the held finger to (x, y) over duration_ms; "end" lifts it; \
                "cancel" always releases the button, held or not. Use it for \
                joysticks, sustained drags, and anything that needs a finger to \
                stay down between other calls. While a touch is held, tap, swipe, \
                drag, long_press and double_tap refuse until it is ended or \
                cancelled. A touch idle for \(Int(TouchSession.defaultInactivityTimeout))s \
                is released automatically. Coordinates are relative to the \
                mirroring window, like tap.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array(touchActions.map { .string($0) }),
                        "description": .string("begin | move | end | cancel"),
                    ]),
                    "x": .object([
                        "type": .string("number"),
                        "description": .string(
                            "X coordinate relative to the mirroring window (begin, move)"),
                    ]),
                    "y": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Y coordinate relative to the mirroring window (begin, move)"),
                    ]),
                    "duration_ms": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Duration of a move in milliseconds, "
                            + "\(TouchSession.minMoveDurationMs)-\(TouchSession.maxMoveDurationMs) "
                            + "(default: \(TouchSession.defaultMoveDurationMs))"),
                    ]),
                ]),
                "required": .array([.string("action")]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err ?? .error("Target could not be resolved") }

                let command: TouchCommand
                switch parseTouchCommand(args) {
                case .success(let parsed): command = parsed
                case .failure(let parseError): return .error(parseError.message)
                }

                switch ctx.input.touch(command) {
                case .success(let outcome): return .text(touchOutcomeText(outcome))
                case .failure(let touchError): return .error(touchError.description)
                }
            }
        ))
    }

    /// Why the touch tool's arguments do not form a command.
    struct TouchArgumentError: Error {
        let message: String
    }

    /// Build a `TouchCommand` from the tool arguments.
    static func parseTouchCommand(
        _ args: [String: JSONValue]
    ) -> Result<TouchCommand, TouchArgumentError> {
        guard let action = args["action"]?.asString() else {
            return .failure(TouchArgumentError(
                message: "Missing required parameter: action (\(touchActions.joined(separator: " | ")))"))
        }
        switch action {
        case "end":
            return .success(.end)
        case "cancel":
            return .success(.cancel)
        case "begin", "move":
            guard let x = args["x"]?.asNumber(), let y = args["y"]?.asNumber() else {
                return .failure(TouchArgumentError(
                    message: "touch(action:\"\(action)\") requires x, y (numbers)"))
            }
            guard x.isFinite, y.isFinite else {
                return .failure(TouchArgumentError(
                    message: "touch(action:\"\(action)\") requires finite x, y coordinates"))
            }
            if action == "begin" {
                return .success(.begin(x: x, y: y))
            }
            // Absent means the default; present but not an Int (NaN, out of
            // range) is refused like any other out-of-range duration.
            let durationMs = args["duration_ms"].map { $0.asInt() } ?? TouchSession.defaultMoveDurationMs
            if let durationError = TouchSession.moveDurationError(durationMs) {
                return .failure(TouchArgumentError(message: durationError))
            }
            guard let durationMs else {
                return .failure(TouchArgumentError(message: "touch move duration_ms is invalid"))
            }
            return .success(.move(x: x, y: y, durationMs: durationMs))
        default:
            return .failure(TouchArgumentError(
                message: "Invalid action '\(action)'. Must be one of: "
                    + touchActions.joined(separator: ", ") + "."))
        }
    }

    /// The tool's success text for a touch outcome.
    static func touchOutcomeText(_ outcome: TouchOutcome) -> String {
        switch outcome {
        case .began(let point):
            return "Touch began at (\(Int(point.x)), \(Int(point.y))) and is held. "
                + "End it with touch(action:\"end\")."
        case .moved(let point):
            return "Touch moved to (\(Int(point.x)), \(Int(point.y))) and is held."
        case .ended(let point):
            return "Touch ended at (\(Int(point.x)), \(Int(point.y)))."
        case .cancelled(let releasedAt?):
            return "Touch cancelled: released at (\(Int(releasedAt.x)), \(Int(releasedAt.y)))."
        case .cancelled(nil):
            return "Touch cancelled: no touch was held; the left button was released anyway."
        }
    }
}
