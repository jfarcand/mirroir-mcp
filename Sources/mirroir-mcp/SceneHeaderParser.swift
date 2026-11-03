// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Reads a kind:game scene skill into a SceneHeader: typed budget, OCR predicates, objective, calibrated controls.
// ABOUTME: Refuses what mirroir-skills' validator refuses, so a scene that would play wrong never starts.

import Foundation

/// Why a scene skill cannot be played.
enum SceneHeaderError: LocalizedError, Equatable {
    case notAGame
    case observeOnly
    case budget(String)
    case predicate(field: String, reason: String)
    case noObjective
    case controls(String)

    var errorDescription: String? {
        switch self {
        case .notAGame:
            return "not a kind:game skill"
        case .observeOnly:
            return "an observe-only scene drives nothing; a scene step needs a playable skill"
        case .budget(let reason):
            return "budget: \(reason)"
        case .predicate(let field, let reason):
            return "\(field): \(reason)"
        case .noObjective:
            return "no ## Objective for the model to play toward"
        case .controls(let reason):
            return "controls: \(reason)"
        }
    }
}

/// Parses a scene skill's front matter and body. Pure: the caller reads the file.
enum SceneHeaderParser {

    /// The budget fields, as written in YAML.
    static let budgetFields = ["max_frames", "max_tokens", "max_seconds"]

    /// The scene skill in `content`, or why it cannot be played.
    static func parse(content: String, name: String) -> Result<SceneHeader, SceneHeaderError> {
        guard SkillParser.isGame(content: content) else { return .failure(.notAGame) }
        let frontMatter = SkillMdParser.extractFrontMatter(content: content)
        if SkillMdParser.extractStringValue(from: frontMatter, key: "playable") == "observe-only" {
            return .failure(.observeOnly)
        }
        let body = SkillMdParser.parseBody(content: content)
        do {
            let budget = try parseBudget(
                SkillMdParser.extractStringValue(from: frontMatter, key: "budget") ?? "")
            guard let successRaw = SkillMdParser.extractStringValue(from: frontMatter, key: "success")
            else {
                throw SceneHeaderError.predicate(field: "success", reason: "missing")
            }
            let success = try parsePredicate(successRaw, field: "success")
            let fail = try SkillMdParser.extractStringValue(from: frontMatter, key: "fail")
                .map { try parsePredicate($0, field: "fail") }
            guard let objective = section("Objective", in: body), !objective.isEmpty else {
                throw SceneHeaderError.noObjective
            }
            let declared = SkillMdParser.extractArrayValue(from: frontMatter, key: "controls")
            let controls = try parseControls(section("Controls", in: body), declared: declared)
            return .success(SceneHeader(
                name: name, budget: budget, controls: controls, objective: objective,
                success: success, fail: fail))
        } catch let error as SceneHeaderError {
            return .failure(error)
        } catch {
            return .failure(.controls(error.localizedDescription))
        }
    }

    /// A budget map: every field present, each a positive integer, no other key.
    static func parseBudget(_ raw: String) throws -> SceneBudget {
        var values: [String: Int] = [:]
        for entry in SkillParser.inlineMapEntries(raw) {
            guard let value = entry.value else {
                throw SceneHeaderError.budget("'\(entry.key)' is not key: value")
            }
            guard budgetFields.contains(entry.key) else {
                throw SceneHeaderError.budget(
                    "unknown field '\(entry.key)' (expected \(budgetFields.joined(separator: ", ")))")
            }
            guard let number = Int(SkillParser.stripQuotes(value)), number > 0 else {
                throw SceneHeaderError.budget("\(entry.key) must be a positive integer (got \(value))")
            }
            values[entry.key] = number
        }
        guard let frames = values["max_frames"], let tokens = values["max_tokens"],
              let seconds = values["max_seconds"] else {
            let missing = budgetFields.filter { values[$0] == nil }
            throw SceneHeaderError.budget("missing \(missing.joined(separator: ", "))")
        }
        return SceneBudget(maxFrames: frames, maxTokens: tokens, maxSeconds: seconds)
    }

    /// A predicate map holding exactly one `visible: "<text>"`.
    static func parsePredicate(_ raw: String, field: String) throws -> ScenePredicate {
        let entries = SkillParser.inlineMapEntries(raw)
        guard entries.count == 1, let entry = entries.first, let value = entry.value else {
            throw SceneHeaderError.predicate(field: field, reason: "must be one { visible: \"<text>\" }")
        }
        guard entry.key == "visible" else {
            throw SceneHeaderError.predicate(field: field, reason: "unknown predicate '\(entry.key)'")
        }
        let text = SkillParser.stripQuotes(value)
        guard !text.isEmpty else {
            throw SceneHeaderError.predicate(field: field, reason: "visible names no text")
        }
        return .visible(text)
    }

    /// The calibrated `## Controls` lines, one per declared control and none other.
    static func parseControls(_ section: String?, declared: [String]) throws -> [SceneControl] {
        guard !declared.isEmpty else { throw SceneHeaderError.controls("none declared") }
        guard let section else { throw SceneHeaderError.controls("no ## Controls section") }
        var controls: [SceneControl] = []
        for rawLine in section.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") else { continue }
            let control = try parseControlLine(line)
            guard !controls.contains(where: { $0.name == control.name }) else {
                throw SceneHeaderError.controls("'\(control.name)' is calibrated twice")
            }
            controls.append(control)
        }
        for name in declared where !controls.contains(where: { $0.name == name }) {
            throw SceneHeaderError.controls("'\(name)' has no line in ## Controls")
        }
        for control in controls where !declared.contains(control.name) {
            throw SceneHeaderError.controls("'\(control.name)' is calibrated but not declared")
        }
        return controls
    }

    /// `- name: tap at X,Y` | `drag from X,Y radius R` | `hold at X,Y for MS`.
    static func parseControlLine(_ line: String) throws -> SceneControl {
        let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let colon = body.firstIndex(of: ":") else {
            throw SceneHeaderError.controls("'\(line)' has no name")
        }
        let name = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
        let words = body[body.index(after: colon)...]
            .split(separator: " ").map(String.init)
        guard !name.isEmpty, !name.contains("+") else {
            throw SceneHeaderError.controls("'\(name)' is not one control")
        }
        let gesture: SceneGesture
        switch (words.first, words.count) {
        case ("tap", 3) where words[1] == "at":
            let point = try fractionPoint(words[2], name: name)
            gesture = .tap(x: point.x, y: point.y)
        case ("drag", 5) where words[1] == "from" && words[3] == "radius":
            let point = try fractionPoint(words[2], name: name)
            let radius = try fraction(words[4], name: name)
            guard radius > 0 else { throw SceneHeaderError.controls("'\(name)' drags a radius of 0") }
            gesture = .drag(x: point.x, y: point.y, radius: radius)
        case ("hold", 5) where words[1] == "at" && words[3] == "for":
            let point = try fractionPoint(words[2], name: name)
            guard let ms = Int(words[4]), ms > 0 else {
                throw SceneHeaderError.controls("'\(name)' must hold for a positive number of ms")
            }
            gesture = .hold(x: point.x, y: point.y, ms: ms)
        default:
            throw SceneHeaderError.controls(
                "'\(line)' is not 'tap at X,Y', 'drag from X,Y radius R' or 'hold at X,Y for MS'")
        }
        return SceneControl(name: name, gesture: gesture)
    }

    /// The text under `## <heading>` up to the next `## `, trimmed; nil when absent.
    static func section(_ heading: String, in body: String) -> String? {
        var collecting = false
        var lines: [String] = []
        for line in body.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                if collecting { break }
                collecting = line.dropFirst(3).trimmingCharacters(in: .whitespaces) == heading
                continue
            }
            if collecting { lines.append(line) }
        }
        guard collecting || !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fractionPoint(_ raw: String, name: String) throws -> (x: Double, y: Double) {
        let parts = raw.split(separator: ",").map(String.init)
        guard parts.count == 2 else {
            throw SceneHeaderError.controls("'\(name)' point '\(raw)' is not X,Y")
        }
        return (try fraction(parts[0], name: name), try fraction(parts[1], name: name))
    }

    private static func fraction(_ raw: String, name: String) throws -> Double {
        guard let value = Double(raw), (0...1).contains(value) else {
            throw SceneHeaderError.controls("'\(name)' value \(raw) is not a window fraction in [0, 1]")
        }
        return value
    }
}
