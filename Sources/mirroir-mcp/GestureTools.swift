// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the pinch and rotate MCP tools: two-finger trackpad gestures on the mirrored iPhone.
// ABOUTME: Parses arguments into a GestureRequest and delegates to InputProviding.gesture.

import Foundation
import HelperLib

extension MirroirMCP {

    /// What every gesture tool description says about how the gesture reaches iOS.
    private static let gestureDeliveryNote = """
        It reaches iOS as a UIKit two-finger gesture, so it works with gesture \
        recognizers such as Maps and Photos; games that read raw touches may ignore it. \
        Needs a Mac with a built-in trackpad or a Magic Trackpad. Refused while a \
        touch is held. Coordinates are relative to the mirroring window, like tap.
        """

    static func registerGestureTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        server.registerTool(MCPToolDefinition(
            name: "pinch",
            description: """
                Two-finger pinch centred at (x, y) on the mirrored iPhone. scale > 1 \
                spreads the fingers (zoom in), scale < 1 pinches them together (zoom \
                out); the distance between the fingers ends at exactly scale times its \
                start (\(GestureRequest.minPinchScale) to \(GestureRequest.maxPinchScale)). \
                \(gestureDeliveryNote)
                """,
            inputSchema: gestureSchema(amountKey: "scale", amountDescription:
                "Finger spread multiplier: > 1 zooms in, < 1 zooms out "
                + "(\(GestureRequest.minPinchScale) to \(GestureRequest.maxPinchScale), not 1)"),
            handler: { args in
                runGesture(args, registry: registry, amountKey: "scale") { x, y, amount, duration in
                    GestureRequest.pinch(x: x, y: y, scale: amount, durationMs: duration)
                }
            }
        ))

        server.registerTool(MCPToolDefinition(
            name: "rotate",
            description: """
                Two-finger rotation centred at (x, y) on the mirrored iPhone by degrees: \
                positive turns counter-clockwise, negative clockwise (up to \
                \(Int(GestureRequest.maxRotateDegrees)) either way). \
                \(gestureDeliveryNote)
                """,
            inputSchema: gestureSchema(amountKey: "degrees", amountDescription:
                "Rotation in degrees: positive counter-clockwise, negative clockwise "
                + "(non-zero, at most \(Int(GestureRequest.maxRotateDegrees)) either way)"),
            handler: { args in
                runGesture(args, registry: registry, amountKey: "degrees") { x, y, amount, duration in
                    GestureRequest.rotate(x: x, y: y, degrees: amount, durationMs: duration)
                }
            }
        ))
    }

    /// Input schema shared by pinch and rotate; only the amount argument differs.
    private static func gestureSchema(amountKey: String,
                                      amountDescription: String) -> [String: JSONValue] {
        [
            "type": .string("object"),
            "properties": .object([
                "x": .object([
                    "type": .string("number"),
                    "description": .string("X coordinate of the gesture centre, relative to the mirroring window"),
                ]),
                "y": .object([
                    "type": .string("number"),
                    "description": .string("Y coordinate of the gesture centre, relative to the mirroring window"),
                ]),
                amountKey: .object([
                    "type": .string("number"),
                    "description": .string(amountDescription),
                ]),
                "duration_ms": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Gesture duration in milliseconds "
                        + "(\(GestureRequest.minDurationMs)-\(GestureRequest.maxDurationMs), "
                        + "default: \(GestureRequest.defaultDurationMs))"),
                ]),
            ]),
            "required": .array([.string("x"), .string("y"), .string(amountKey)]),
        ]
    }

    /// Parse the shared arguments, build the request, and hand it to the target's input.
    private static func runGesture(
        _ args: [String: JSONValue],
        registry: TargetRegistry,
        amountKey: String,
        makeRequest: (Double, Double, Double, Int) -> Result<GestureRequest, GestureArgumentError>
    ) -> MCPToolResult {
        let (ctx, err) = registry.resolveForTool(args)
        guard let ctx else { return err ?? .error("Target could not be resolved") }

        guard let x = args["x"]?.asNumber(), let y = args["y"]?.asNumber(),
              let amount = args[amountKey]?.asNumber() else {
            return .error("Missing required parameters: x, y, \(amountKey) (numbers)")
        }
        let durationMs = args["duration_ms"]?.asInt() ?? GestureRequest.defaultDurationMs

        let request: GestureRequest
        switch makeRequest(x, y, amount, durationMs) {
        case .success(let built): request = built
        case .failure(let argumentError): return .error(argumentError.message)
        }

        if let error = ctx.input.gesture(request) {
            return .error(error)
        }
        return .text(gestureSuccessText(request))
    }

    /// The tool's success text for a performed gesture.
    static func gestureSuccessText(_ request: GestureRequest) -> String {
        let centre = "(\(Int(request.x)), \(Int(request.y)))"
        switch request.gesture {
        case .pinch(let scale):
            return "Pinched at \(centre) to \(scale)x over \(request.durationMs)ms"
        case .rotate(let degrees):
            return "Rotated at \(centre) by \(degrees) degrees over \(request.durationMs)ms"
        }
    }
}
