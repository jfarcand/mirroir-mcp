// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Value types of a `scene:` step: its budget, the scene skill's calibrated controls and OCR predicates, the run's report.
// ABOUTME: Pure data shared by SceneHeaderParser, SceneLoop, the step executor and the report writer.

import Foundation
import HelperLib

/// The hard limits a scene plays under. It stops at the first one it reaches.
struct SceneBudget: Equatable, Sendable {
    /// Most model calls (frames) the scene may make.
    let maxFrames: Int
    /// Most prompt plus completion tokens, summed over every frame.
    let maxTokens: Int
    /// Most wall-clock seconds, from the first frame to the last.
    let maxSeconds: Int

    /// The fields of `self` that exceed `limit`, named as written in YAML.
    /// A step budget may only narrow its skill's budget.
    func fieldsExceeding(_ limit: SceneBudget) -> [String] {
        var fields: [String] = []
        if maxFrames > limit.maxFrames { fields.append("max_frames") }
        if maxTokens > limit.maxTokens { fields.append("max_tokens") }
        if maxSeconds > limit.maxSeconds { fields.append("max_seconds") }
        return fields
    }
}

/// The one touch a scene control makes, in window fractions (0...1) so it
/// scales with the mirror window and its orientation.
enum SceneGesture: Equatable, Sendable {
    /// A tap at a point.
    case tap(x: Double, y: Double)
    /// A drag from a point, `radius` far, in the direction the model picks.
    case drag(x: Double, y: Double, radius: Double)
    /// A press held at a point for `ms` milliseconds.
    case hold(x: Double, y: Double, ms: Int)
    /// A board of `cols` x `rows` equal cells between its top-left corner
    /// (`x0`, `y0`) and bottom-right corner (`x1`, `y1`). An action names cells
    /// by screen position: column letter from the left, row number from the bottom.
    case grid(cols: Int, rows: Int, x0: Double, y0: Double, x1: Double, y1: Double)

    /// The window-fraction center of `cell` ("a1" = bottom-left) on a grid
    /// gesture, or nil when this is not a grid or the cell is not on it.
    func cellCenter(_ cell: String) -> (x: Double, y: Double)? {
        guard case .grid(let cols, let rows, let x0, let y0, let x1, let y1) = self,
              let (col, row) = SceneGesture.cellIndex(cell, cols: cols, rows: rows) else { return nil }
        let x = x0 + (Double(col) + 0.5) * (x1 - x0) / Double(cols)
        let y = y1 - (Double(row) - 0.5) * (y1 - y0) / Double(rows)
        return (x, y)
    }

    /// The 0-based column and 1-based row of `cell` on a `cols` x `rows` grid, or
    /// nil when it is not one letter a... followed by a row number in range.
    static func cellIndex(_ cell: String, cols: Int, rows: Int) -> (col: Int, row: Int)? {
        guard let letter = cell.first, let ascii = letter.asciiValue,
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(ascii),
              let row = Int(cell.dropFirst()), String(row) == String(cell.dropFirst()) else { return nil }
        let col = Int(ascii - UInt8(ascii: "a"))
        guard col < cols, (1...rows).contains(row) else { return nil }
        return (col, row)
    }
}

/// A drag direction the model may pick for a drag control.
enum SceneDirection: String, CaseIterable, Sendable {
    case up, down, left, right
    case upLeft = "up-left"
    case upRight = "up-right"
    case downLeft = "down-left"
    case downRight = "down-right"

    /// Unit vector in window space (y grows downward).
    var vector: (dx: Double, dy: Double) {
        let diagonal = 1 / 2.0.squareRoot()
        switch self {
        case .up: return (0, -1)
        case .down: return (0, 1)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        case .upLeft: return (-diagonal, -diagonal)
        case .upRight: return (diagonal, -diagonal)
        case .downLeft: return (-diagonal, diagonal)
        case .downRight: return (diagonal, diagonal)
        }
    }
}

/// A named control of the scene skill, calibrated on the device in `## Controls`.
struct SceneControl: Equatable, Sendable {
    /// The name an action uses for "no touch this frame"; never a declared control.
    static let waitName = "none"

    let name: String
    let gesture: SceneGesture

    /// The kind a move picker is told: tap, drag, hold or grid.
    var kind: String {
        switch gesture {
        case .tap: return "tap"
        case .drag: return "drag"
        case .hold: return "hold"
        case .grid: return "grid"
        }
    }
}

/// A condition read from a frame's OCR, never from the model.
enum ScenePredicate: Equatable, Sendable {
    /// The text is on screen, matched as `wait_for` and `assert_visible` match.
    case visible(String)

    /// Whether `elements` (one frame's OCR) meet the predicate.
    func isMet(by elements: [TapPoint]) -> Bool {
        switch self {
        case .visible(let text):
            return ElementMatcher.isVisible(label: text, in: elements)
        }
    }
}

/// What a scene skill declares for a `scene:` step to play it.
struct SceneHeader: Equatable, Sendable {
    /// The skill's name, as reported.
    let name: String
    /// The upper limit any step budget must stay within.
    let budget: SceneBudget
    /// The calibrated controls, in declaration order.
    let controls: [SceneControl]
    /// The `## Objective` text the model plays toward.
    let objective: String
    /// Met when any of these is met.
    let success: [ScenePredicate]
    /// Read before `success`; met when any of these is met. Empty when the skill declares none.
    let fail: [ScenePredicate]
    /// Width the frame is resized to before it is sent; nil keeps the configured default.
    let imageWidth: Int?
    /// The skill declares `decider: required`: the model reads the frame and an
    /// external move picker named by the scenario chooses the action.
    let needsDecider: Bool

    /// Whether any of `predicates` is met by one frame's OCR.
    static func anyMet(_ predicates: [ScenePredicate], by elements: [TapPoint]) -> Bool {
        predicates.contains { $0.isMet(by: elements) }
    }
}

/// Whether a scene met its goal, failed it, or ran out of budget first.
enum SceneVerdict: String, Sendable {
    case pass
    case fail
    /// The budget ran out before either predicate: never a pass.
    case inconclusive
}

/// Why a scene stopped.
enum SceneStopReason: String, Sendable {
    case success
    case fail
    case maxFrames = "max_frames"
    case maxTokens = "max_tokens"
    case maxSeconds = "max_seconds"
    /// The model reported no token usage, so the token budget cannot hold.
    case usageMissing = "usage_missing"
    /// A frame could not be read, so no predicate can be judged on it.
    case perceptionFailed = "perception_failed"
    /// The chosen control's touch could not be posted.
    case inputFailed = "input_failed"
    /// The move picker exited non-zero, timed out with time left, or answered
    /// no allowed action.
    case deciderFailed = "decider_failed"

    var verdict: SceneVerdict {
        switch self {
        case .success: return .pass
        case .fail, .usageMissing, .perceptionFailed, .inputFailed, .deciderFailed: return .fail
        case .maxFrames, .maxTokens, .maxSeconds: return .inconclusive
        }
    }
}

/// A scene run's evidence summary: the `scenes` entry of the report captures.
struct SceneReport: Encodable, Equatable, Sendable {
    let skill: String
    let verdict: SceneVerdict
    let reason: SceneStopReason
    /// Model calls made.
    let frames: Int
    /// Frames taken to meet the success predicate; nil unless the verdict is pass.
    let framesToPredicate: Int?
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let seconds: Double
    /// The model the request named: the drift key, so runs are compared only
    /// with runs of the same model.
    let model: String
    /// The model the API said answered, when it said.
    let responseModel: String?
    /// Replies that named no allowed control: no touch, but budget spent.
    let rejectedReplies: Int
    /// Frames whose action was `none`: no touch, but budget spent.
    let waits: Int
    /// Calls made to the external move picker; 0 when the scene has none.
    let deciderCalls: Int
    /// Where the frames and per-frame log were written.
    let evidenceDir: String

    enum CodingKeys: String, CodingKey {
        case skill, verdict, reason, frames, model, seconds
        case framesToPredicate = "frames_to_predicate"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case responseModel = "response_model"
        case rejectedReplies = "rejected_replies"
        case waits
        case deciderCalls = "decider_calls"
        case evidenceDir = "evidence_dir"
    }

    /// Writes every key, an absent value as `null`, so the captures shape is fixed.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(skill, forKey: .skill)
        try container.encode(verdict.rawValue, forKey: .verdict)
        try container.encode(reason.rawValue, forKey: .reason)
        try container.encode(frames, forKey: .frames)
        try container.encode(framesToPredicate, forKey: .framesToPredicate)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(completionTokens, forKey: .completionTokens)
        try container.encode(totalTokens, forKey: .totalTokens)
        try container.encode(seconds, forKey: .seconds)
        try container.encode(model, forKey: .model)
        try container.encode(responseModel, forKey: .responseModel)
        try container.encode(rejectedReplies, forKey: .rejectedReplies)
        try container.encode(waits, forKey: .waits)
        try container.encode(deciderCalls, forKey: .deciderCalls)
        try container.encode(evidenceDir, forKey: .evidenceDir)
    }

    /// The report's failure line for a scene that did not pass; nil on a pass.
    var failureLine: String? {
        switch verdict {
        case .pass: return nil
        case .fail: return "SCENE FAIL: \(skill): \(reason.rawValue)"
        case .inconclusive:
            return "INCONCLUSIVE: \(skill): \(reason.rawValue) "
                + "(\(frames) frames, \(totalTokens) tokens)"
        }
    }
}
