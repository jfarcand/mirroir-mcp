// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The scene model's instructions and the strict reading of its reply into one allowed control.
// ABOUTME: The model only names a control (and a direction for a drag); positions come from the calibrated skill.

import Foundation

/// What the model chose for one frame.
struct SceneAction: Equatable, Sendable {
    let control: SceneControl
    /// The drag direction; nil for a tap or hold control.
    let direction: SceneDirection?
    let rationale: String
}

/// Builds the scene system prompt and parses replies.
enum ScenePrompt {

    /// The system prompt for `header`: the objective, the controls by name and
    /// kind, and the exact reply shape.
    static func systemPrompt(for header: SceneHeader) -> String {
        let directions = SceneDirection.allCases.map(\.rawValue).joined(separator: ", ")
        let controls = header.controls.map { control -> String in
            switch control.gesture {
            case .tap: return "- \(control.name): a tap"
            case .hold: return "- \(control.name): a press held in place"
            case .drag: return "- \(control.name): a drag; also pick a direction (\(directions))"
            }
        }.joined(separator: "\n")
        return """
            You play a mobile game, one touch per frame. Each message is the current \
            frame. Pick the single control that best advances the objective.

            Objective:
            \(header.objective)

            Controls:
            \(controls)

            Reply with ONLY this JSON object, no other text:
            {"control": "<control name>", "direction": "<direction, only for a drag control>", \
            "rationale": "<one short sentence on what you see and why>"}
            """
    }

    /// The action `reply` names, or nil when it is anything but exactly one
    /// allowed control: unknown keys, an unknown control, a direction on a
    /// non-drag control, a drag with none, or not a JSON object at all. One
    /// optional ```json fence around the object is accepted.
    static func parseAction(_ reply: String, controls: [SceneControl]) -> SceneAction? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            guard text.hasSuffix("```"), let firstNewline = text.firstIndex(of: "\n") else { return nil }
            text = String(text[text.index(after: firstNewline)..<text.index(text.endIndex, offsetBy: -3)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["control", "direction", "rationale"]),
              let name = object["control"] as? String,
              let rationale = object["rationale"] as? String,
              let control = controls.first(where: { $0.name == name }) else { return nil }
        let direction = object["direction"] as? String
        if case .drag = control.gesture {
            guard let raw = direction, let parsed = SceneDirection(rawValue: raw) else { return nil }
            return SceneAction(control: control, direction: parsed, rationale: rationale)
        }
        guard direction == nil || direction?.isEmpty == true else { return nil }
        return SceneAction(control: control, direction: nil, rationale: rationale)
    }
}
