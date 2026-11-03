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
    let name: String
    let gesture: SceneGesture
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
    let success: ScenePredicate
    let fail: ScenePredicate?
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

    var verdict: SceneVerdict {
        switch self {
        case .success: return .pass
        case .fail, .usageMissing, .perceptionFailed, .inputFailed: return .fail
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
