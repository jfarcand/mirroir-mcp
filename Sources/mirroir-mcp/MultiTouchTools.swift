// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the multi_touch MCP tool: up to ten independent fingers played through WebDriverAgent.
// ABOUTME: Parses per-finger timelines from the arguments and delegates to MultiTouchPlayback.

import CoreGraphics
import Foundation
import HelperLib

/// Why the multi_touch arguments cannot be turned into finger timelines.
struct MultiTouchArgumentError: Error, Equatable {
    let message: String
}

extension MirroirMCP {

    /// Step actions accepted in a finger's `steps`.
    enum MultiTouchStepAction: String, CaseIterable {
        case down, move, up
    }

    static func registerMultiTouchTools(
        server: MCPServer,
        registry: TargetRegistry,
        playback: MultiTouchPlayback = .shared
    ) {
        server.registerTool(MCPToolDefinition(
            name: MultiTouchPlayback.toolName,
            description: """
                Play up to \(MultiTouchGesture.maxFingers) independent fingers at once on the \
                iPhone, each with its own timeline: down at (x, y) at at_ms, moves over \
                duration_ms, up at at_ms. Times are milliseconds from the start of the \
                gesture, so fingers can start, hold, move, and lift independently (hold a \
                joystick while tapping a button). The whole gesture plays in one call and \
                every finger must lift by its end: a finger cannot stay down between calls. \
                Needs a WebDriverAgent runner on the iPhone (MIRROIR_WDA_URL or wda_url); \
                iPhone Mirroring itself carries only one touch. Refused while a touch is \
                held. Coordinates are relative to the mirroring window, like tap.
                """,
            inputSchema: multiTouchSchema(),
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err ?? .error("Target could not be resolved") }

                let timelines: [FingerTimeline]
                switch parseMultiTouch(args) {
                case .success(let parsed): timelines = parsed
                case .failure(let argumentError): return .error(argumentError.message)
                }
                let outcome = playback.play(timelines, window: ctx.bridge.getWindowInfo(),
                                            targetName: ctx.name,
                                            urlOverride: args["wda_url"]?.asString())
                switch outcome {
                case .success(let played): return .text(multiTouchSuccessText(played))
                case .failure(let error): return .error(error.description)
                }
            }
        ))
    }

    /// Finger timelines from the tool arguments, or which argument is wrong.
    static func parseMultiTouch(_ args: [String: JSONValue]) -> Result<[FingerTimeline], MultiTouchArgumentError> {
        guard case .array(let fingers) = args["fingers"] else {
            return .failure(MultiTouchArgumentError(
                message: "Missing required parameter: fingers (array of {id, steps})"))
        }
        var timelines: [FingerTimeline] = []
        for (index, finger) in fingers.enumerated() {
            guard case .object(let fields) = finger, let id = fields["id"]?.asInt() else {
                return .failure(MultiTouchArgumentError(
                    message: "fingers[\(index)] needs an integer id"))
            }
            guard case .array(let steps) = fields["steps"] else {
                return .failure(MultiTouchArgumentError(
                    message: "finger \(id) needs steps (array of {action, x, y, at_ms, duration_ms})"))
            }
            var parsed: [FingerStep] = []
            for (stepIndex, step) in steps.enumerated() {
                switch parseStep(step, finger: id, index: stepIndex) {
                case .success(let fingerStep): parsed.append(fingerStep)
                case .failure(let error): return .failure(error)
                }
            }
            timelines.append(FingerTimeline(id: id, steps: parsed))
        }
        return .success(timelines)
    }

    /// One step from its JSON object.
    private static func parseStep(_ value: JSONValue, finger: Int,
                                  index: Int) -> Result<FingerStep, MultiTouchArgumentError> {
        let place = "finger \(finger) step \(index)"
        let actions = MultiTouchStepAction.allCases.map(\.rawValue).joined(separator: ", ")
        guard case .object(let fields) = value,
              let action = fields["action"]?.asString().flatMap(MultiTouchStepAction.init(rawValue:)) else {
            return .failure(MultiTouchArgumentError(message: "\(place) needs an action: one of \(actions)"))
        }
        if let raw = fields["at_ms"], raw.asInt() == nil {
            return .failure(MultiTouchArgumentError(message: "\(place): at_ms must be an integer"))
        }
        let atMs = fields["at_ms"]?.asInt()
        switch action {
        case .up:
            return .success(.up(atMs: atMs))
        case .down, .move:
            guard let x = fields["x"]?.asNumber(), let y = fields["y"]?.asNumber() else {
                return .failure(MultiTouchArgumentError(message: "\(place): \(action.rawValue) needs x and y"))
            }
            let point = CGPoint(x: x, y: y)
            guard action == .move else { return .success(.down(point: point, atMs: atMs)) }
            guard let durationMs = fields["duration_ms"]?.asInt() else {
                return .failure(MultiTouchArgumentError(
                    message: "\(place): move needs duration_ms (integer milliseconds)"))
            }
            return .success(.move(to: point, atMs: atMs, durationMs: durationMs))
        }
    }

    /// The tool's success text: what was played, per finger, in device points.
    static func multiTouchSuccessText(_ played: MultiTouchPlayed) -> String {
        let gesture = played.report.gesture
        let device = "\(Int(gesture.bounds.width))x\(Int(gesture.bounds.height))"
        let os = played.osVersion.map { " (\($0))" } ?? ""
        var lines = ["Played \(gesture.paths.count) finger(s) over \(gesture.durationMs)ms through "
            + "WebDriverAgent at \(played.runnerURL.absoluteString)\(os); device viewport \(device) "
            + "points; answered after \(played.report.elapsedMs)ms."]
        for path in gesture.paths {
            var steps = ["down \(point(path.downPoint)) @\(path.downMs)ms"]
            steps += path.moves.map { "move to \(point($0.to)) \($0.startMs)-\($0.endMs)ms" }
            steps.append("up @\(path.upMs)ms")
            lines.append("  finger \(path.id): " + steps.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private static func point(_ value: CGPoint) -> String {
        func format(_ component: CGFloat) -> String {
            component == component.rounded() ? String(Int(component)) : String(format: "%.2f", Double(component))
        }
        return "(\(format(value.x)), \(format(value.y)))"
    }

    private static func multiTouchSchema() -> [String: JSONValue] {
        let step: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "enum": .array(MultiTouchStepAction.allCases.map { .string($0.rawValue) }),
                    "description": .string("down (first step), move, or up (last step)"),
                ]),
                "x": .object(["type": .string("number"),
                              "description": .string("X relative to the mirroring window (down, move)")]),
                "y": .object(["type": .string("number"),
                              "description": .string("Y relative to the mirroring window (down, move)")]),
                "at_ms": .object(["type": .string("integer"), "description": .string(
                    "When the step starts, in ms from the start of the gesture. Default: 0 for down, "
                    + "the end of the previous step for move and up")]),
                "duration_ms": .object(["type": .string("integer"), "description": .string(
                    "How long a move takes, in ms (\(MultiTouchGesture.minMoveDurationMs)-"
                    + "\(MultiTouchGesture.maxDurationMs))")]),
            ]),
            "required": .array([.string("action")]),
        ]
        let finger: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("integer"),
                               "description": .string("Finger id, unique within the gesture")]),
                "steps": .object(["type": .string("array"), "items": .object(step),
                                  "description": .string("down, then any moves, then up")]),
            ]),
            "required": .array([.string("id"), .string("steps")]),
        ]
        return [
            "type": .string("object"),
            "properties": .object([
                "fingers": .object([
                    "type": .string("array"),
                    "items": .object(finger),
                    "description": .string(
                        "\(MultiTouchGesture.minFingers)-\(MultiTouchGesture.maxFingers) fingers; "
                        + "the gesture lasts at most \(MultiTouchGesture.maxDurationMs)ms"),
                ]),
                "wda_url": .object([
                    "type": .string("string"),
                    "description": .string(
                        "WebDriverAgent URL, e.g. http://<iphone-ip>:8100 (default: MIRROIR_WDA_URL)"),
                ]),
            ]),
            "required": .array([.string("fingers")]),
        ]
    }
}
