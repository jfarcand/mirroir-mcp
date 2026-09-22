// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the hold_keys MCP tool: hold keyboard keys, optionally while dragging a mouse button.
// ABOUTME: Parses arguments into a HeldKeysRequest and delegates to InputProviding.holdKeys.

import Foundation
import HelperLib

extension MirroirMCP {

    static func registerHoldKeysTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        server.registerTool(MCPToolDefinition(
            name: HeldKeysRequest.toolName,
            description: """
                Hold keyboard keys down for duration_ms, optionally while dragging a mouse \
                button across the mirrored iPhone, then release everything. For games that \
                switch to mouse/keyboard controls (e.g. Roblox): hold "w" to walk while a \
                right-button drag turns the camera. Touch-only games ignore keys. Held keys \
                repeat like a physical key; modifiers (shift, control, option, command) are \
                held without repeating. Refused while a touch is held. Drag coordinates are \
                relative to the mirroring window, like drag.
                """,
            inputSchema: holdKeysSchema(),
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err ?? .error("Target could not be resolved") }

                let request: HeldKeysRequest
                switch parseHoldKeys(args) {
                case .success(let built): request = built
                case .failure(let argumentError): return .error(argumentError.message)
                }
                if let error = ctx.input.holdKeys(request) {
                    return .error(error)
                }
                return .text(holdKeysSuccessText(request))
            }
        ))
    }

    /// Build a request from the tool arguments, or say which argument is wrong.
    static func parseHoldKeys(_ args: [String: JSONValue]) -> Result<HeldKeysRequest, HeldKeysArgumentError> {
        guard case .array(let items) = args["keys"] else {
            return .failure(HeldKeysArgumentError(
                message: "Missing required parameter: keys (array of key names)"))
        }
        var keyNames: [String] = []
        for item in items {
            guard let name = item.asString() else {
                return .failure(HeldKeysArgumentError(message: "keys must contain only strings"))
            }
            keyNames.append(name)
        }
        let durationMs = args["duration_ms"]?.asInt() ?? HeldKeysRequest.defaultDurationMs

        var drag: HeldKeysDrag?
        if let dragValue = args["drag"] {
            guard let fromX = dragValue.getNumber("from_x"), let fromY = dragValue.getNumber("from_y"),
                  let toX = dragValue.getNumber("to_x"), let toY = dragValue.getNumber("to_y") else {
                return .failure(HeldKeysArgumentError(
                    message: "drag requires from_x, from_y, to_x, to_y (numbers)"))
            }
            let buttonName = dragValue.getString("button") ?? DragButton.left.rawValue
            guard let button = DragButton(rawValue: buttonName) else {
                return .failure(HeldKeysArgumentError(
                    message: "drag button must be one of: "
                        + "\(DragButton.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(buttonName)')"))
            }
            drag = HeldKeysDrag(fromX: fromX, fromY: fromY, toX: toX, toY: toY, button: button)
        }
        return HeldKeysRequest.make(keyNames: keyNames, durationMs: durationMs, drag: drag)
    }

    /// The tool's success text for a performed hold.
    static func holdKeysSuccessText(_ request: HeldKeysRequest) -> String {
        let keys = request.keys.map(\.name).joined(separator: ", ")
        var text = "Held \(keys) for \(request.durationMs)ms"
        if let drag = request.drag {
            text += " while \(drag.button.rawValue)-dragging from (\(Int(drag.fromX)), \(Int(drag.fromY))) "
                + "to (\(Int(drag.toX)), \(Int(drag.toY)))"
        }
        return text
    }

    private static func holdKeysSchema() -> [String: JSONValue] {
        let coordinate: (String) -> JSONValue = { description in
            .object(["type": .string("number"), "description": .string(description)])
        }
        return [
            "type": .string("object"),
            "properties": .object([
                "keys": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "minItems": .number(Double(HeldKeysRequest.minKeys)),
                    "maxItems": .number(Double(HeldKeysRequest.maxKeys)),
                    "description": .string(
                        "Keys to hold (\(HeldKeysRequest.minKeys)-\(HeldKeysRequest.maxKeys)): single "
                        + "characters typed without modifiers (\"w\", \"a\", \"1\"), modifiers "
                        + "(\(CGEventInput.modifierNames.joined(separator: ", "))), or named keys "
                        + "(\(AppleScriptKeyMap.supportedKeys.joined(separator: ", ")))"),
                ]),
                "duration_ms": .object([
                    "type": .string("number"),
                    "description": .string(
                        "How long to hold, in milliseconds "
                        + "(\(HeldKeysRequest.minDurationMs)-\(HeldKeysRequest.maxDurationMs), "
                        + "default: \(HeldKeysRequest.defaultDurationMs))"),
                ]),
                "drag": .object([
                    "type": .string("object"),
                    "description": .string(
                        "Optional mouse-button drag performed over the same duration while the keys are held"),
                    "properties": .object([
                        "from_x": coordinate("Drag start X, relative to the mirroring window"),
                        "from_y": coordinate("Drag start Y, relative to the mirroring window"),
                        "to_x": coordinate("Drag end X, relative to the mirroring window"),
                        "to_y": coordinate("Drag end Y, relative to the mirroring window"),
                        "button": .object([
                            "type": .string("string"),
                            "enum": .array(DragButton.allCases.map { .string($0.rawValue) }),
                            "description": .string(
                                "Mouse button to hold (default: left). Games with mouse controls "
                                + "usually turn the camera with right."),
                        ]),
                    ]),
                    "required": .array([.string("from_x"), .string("from_y"),
                                        .string("to_x"), .string("to_y")]),
                ]),
            ]),
            "required": .array([.string("keys")]),
        ]
    }
}
