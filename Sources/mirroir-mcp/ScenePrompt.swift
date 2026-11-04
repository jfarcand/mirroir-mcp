// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The scene model's instructions and the strict reading of a reply into one allowed action, or a board reading.
// ABOUTME: Replies only name a control, its direction or cells, or none; positions come from the calibrated skill.

import Foundation

/// What one frame does: a control and how to use it, or a wait (no touch).
struct SceneAction: Equatable, Sendable {
    /// The control touched; nil for a wait (`none`).
    let control: SceneControl?
    /// The drag direction; nil unless the control is a drag.
    let direction: SceneDirection?
    /// The grid cells tapped in order; empty unless the control is a grid.
    let cells: [String]
    let rationale: String

    /// No touch this frame.
    var isWait: Bool { control == nil }

    /// The name the action used, `none` for a wait.
    var controlName: String { control?.name ?? SceneControl.waitName }
}

/// Builds the scene system prompts and parses replies.
enum ScenePrompt {

    /// Most cells one action may tap: a move, plus a promotion or confirmation.
    static let maxCells = 4

    /// The system prompt for `header`. With a move picker the model only reads
    /// the frame into the text the objective defines; otherwise it picks the action.
    static func systemPrompt(for header: SceneHeader) -> String {
        if header.needsDecider {
            return """
                You read the frames of a mobile game. Each message is the current frame. \
                Read it into exactly the text the objective asks for; another program \
                chooses the move from your reading.

                Objective:
                \(header.objective)

                Reply with ONLY this JSON object, no other text:
                {"reading": "<the text the objective asks for>", \
                "rationale": "<one short sentence on what you see>"}
                """
        }
        return """
            You play a mobile game, one action per frame. Each message is the current \
            frame. Pick the single action that best advances the objective.

            Objective:
            \(header.objective)

            Controls:
            \(controlLines(header.controls))
            - \(SceneControl.waitName): touch nothing this frame and look again

            Reply with ONLY this JSON object, no other text. "control" is exactly one \
            of these names: \(controlNames(header.controls)).
            {"control": "<control name>", "direction": "<only for a drag control>", \
            "cells": ["<only for a grid control>"], \
            "rationale": "<one short sentence on what you see and why>"}
            """
    }

    /// The names a reply may use, quoted: the declared controls and `none`.
    private static func controlNames(_ controls: [SceneControl]) -> String {
        (controls.map(\.name) + [SceneControl.waitName]).map { "\"\($0)\"" }.joined(separator: ", ")
    }

    private static func controlLines(_ controls: [SceneControl]) -> String {
        let directions = SceneDirection.allCases.map(\.rawValue).joined(separator: ", ")
        return controls.map { control -> String in
            switch control.gesture {
            case .tap: return "- \(control.name): a tap"
            case .hold: return "- \(control.name): a press held in place"
            case .drag: return "- \(control.name): a drag; also pick a direction (\(directions))"
            case .grid(let cols, let rows, _, _, _, _):
                let lastColumn = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(cols - 1)))
                return "- \(control.name): a \(cols)x\(rows) board; list 1 to \(maxCells) cells to tap "
                    + "in order, named by screen position: column a (left) to \(lastColumn) (right), "
                    + "row 1 (bottom) to \(rows) (top), e.g. [\"a1\", \"\(lastColumn)\(rows)\"]"
            }
        }.joined(separator: "\n")
    }

    /// The action `reply` names, or nil when it is anything but exactly one
    /// allowed action: unknown keys, an unknown control, a direction or cells on
    /// the wrong kind of control, a missing direction or cells, an unknown cell,
    /// or no JSON object ending the reply. `rationaleRequired` is false for a move
    /// picker's answer. Prose before the object, and one ```json fence around it, are accepted.
    static func parseAction(
        _ reply: String, controls: [SceneControl], rationaleRequired: Bool = true
    ) -> SceneAction? {
        guard let object = jsonObject(reply),
              Set(object.keys).isSubset(of: ["control", "direction", "cells", "rationale"]),
              let name = object["control"] as? String else { return nil }
        let rationale = object["rationale"] as? String
        if rationaleRequired && rationale == nil { return nil }
        // The reply template lists every key; an empty one means "not used".
        let direction = (object["direction"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var cells: Any? = object["cells"]
        if let list = cells as? [Any], list.isEmpty { cells = nil }
        if name == SceneControl.waitName {
            guard direction == nil, cells == nil else { return nil }
            return SceneAction(control: nil, direction: nil, cells: [], rationale: rationale ?? "")
        }
        guard let control = controls.first(where: { $0.name == name }) else { return nil }
        switch control.gesture {
        case .drag:
            guard cells == nil, let raw = direction, let parsed = SceneDirection(rawValue: raw) else { return nil }
            return SceneAction(control: control, direction: parsed, cells: [], rationale: rationale ?? "")
        case .grid:
            guard direction == nil, let list = cells as? [String], (1...maxCells).contains(list.count),
                  list.allSatisfy({ control.gesture.cellCenter($0) != nil }) else { return nil }
            return SceneAction(control: control, direction: nil, cells: list, rationale: rationale ?? "")
        case .tap, .hold:
            guard direction == nil, cells == nil else { return nil }
            return SceneAction(control: control, direction: nil, cells: [], rationale: rationale ?? "")
        }
    }

    /// The board reading in a reply to the reading prompt, or nil when the reply
    /// is not exactly `{"reading": "...", "rationale": "..."}` with a non-empty reading.
    static func parseReading(_ reply: String) -> String? {
        guard let object = jsonObject(reply),
              Set(object.keys) == ["reading", "rationale"],
              let reading = object["reading"] as? String, !reading.isEmpty,
              object["rationale"] is String else { return nil }
        return reading
    }

    /// The JSON object that ends `reply`. A model may reason in prose first (it
    /// reads a board better when it does), so text before the object is skipped;
    /// nothing may follow it but one closing ``` fence.
    private static func jsonObject(_ reply: String) -> [String: Any]? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
            guard let open = text.range(of: "```", options: .backwards) else { return nil }
            let afterFence = text[open.upperBound...]
            guard let newline = afterFence.firstIndex(of: "\n") else { return nil }
            text = String(text[..<open.lowerBound]) + String(afterFence[afterFence.index(after: newline)...])
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.hasSuffix("}") else { return nil }
        // The earliest brace whose remainder parses is the object that ends the reply.
        var index = text.startIndex
        while let brace = text[index...].firstIndex(of: "{") {
            if let data = String(text[brace...]).data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                return object
            }
            index = text.index(after: brace)
        }
        return nil
    }
}
