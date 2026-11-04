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
    case imageWidth(String)
    case decider(String)

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
        case .imageWidth(let reason):
            return "image_width: \(reason)"
        case .decider(let reason):
            return "decider: \(reason)"
        }
    }
}

/// Parses a scene skill's front matter and body. Pure: the caller reads the file.
enum SceneHeaderParser {

    /// The budget fields, as written in YAML.
    static let budgetFields = ["max_frames", "max_tokens", "max_seconds"]
    /// The narrowest and widest frame a skill may ask the model to read.
    static let imageWidthRange = 200...2000
    /// Most columns a grid may have: one letter a...z each.
    static let maxGridColumns = 26
    /// Most rows a grid may have.
    static let maxGridRows = 99

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
                .map { try parsePredicate($0, field: "fail") } ?? []
            let imageWidth = try parseImageWidth(
                SkillMdParser.extractStringValue(from: frontMatter, key: "image_width"))
            let needsDecider = try parseDecider(
                SkillMdParser.extractStringValue(from: frontMatter, key: "decider"))
            guard let objective = section("Objective", in: body), !objective.isEmpty else {
                throw SceneHeaderError.noObjective
            }
            let declared = SkillMdParser.extractArrayValue(from: frontMatter, key: "controls")
            let controls = try parseControls(section("Controls", in: body), declared: declared)
            return .success(SceneHeader(
                name: name, budget: budget, controls: controls, objective: objective,
                success: success, fail: fail, imageWidth: imageWidth, needsDecider: needsDecider))
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

    /// A predicate map holding one `visible:` naming a text or a list of texts:
    /// `{ visible: "GOAL" }` or `{ visible: ["Vaincu", "Quitter"] }`. A list is met
    /// when any of its texts is visible.
    static func parsePredicate(_ raw: String, field: String) throws -> [ScenePredicate] {
        let entries = SkillParser.inlineMapEntries(raw)
        let shape = "must be one { visible: \"<text>\" } or { visible: [\"<text>\", ...] }"
        guard let first = entries.first, let firstValue = first.value else {
            throw SceneHeaderError.predicate(field: field, reason: shape)
        }
        guard first.key == "visible" else {
            throw SceneHeaderError.predicate(field: field, reason: "unknown predicate '\(first.key)'")
        }
        let texts: [String]
        if firstValue.hasPrefix("[") {
            // A list is split at its commas, so rejoin the entries the map split
            // inside the brackets and require it to close with nothing after it.
            let list = ([firstValue] + entries.dropFirst().map { entry in
                entry.value.map { "\(entry.key):\($0)" } ?? entry.key
            }).joined(separator: ",").trimmingCharacters(in: .whitespaces)
            guard list.hasSuffix("]") else {
                throw SceneHeaderError.predicate(field: field, reason: "visible list is not closed")
            }
            texts = TargetSelector.splitTopLevel(String(list.dropFirst().dropLast()))
                .map { SkillParser.stripQuotes($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
            guard !texts.isEmpty else {
                throw SceneHeaderError.predicate(field: field, reason: "visible list is empty")
            }
        } else {
            guard entries.count == 1 else { throw SceneHeaderError.predicate(field: field, reason: shape) }
            texts = [SkillParser.stripQuotes(firstValue)]
        }
        guard texts.allSatisfy({ !$0.isEmpty }) else {
            throw SceneHeaderError.predicate(field: field, reason: "visible names no text")
        }
        return texts.map { .visible($0) }
    }

    /// An optional `image_width`: a whole number of pixels in `imageWidthRange`.
    static func parseImageWidth(_ raw: String?) throws -> Int? {
        guard let raw else { return nil }
        guard let width = Int(raw), imageWidthRange.contains(width) else {
            throw SceneHeaderError.imageWidth(
                "\(raw) is not a width in \(imageWidthRange.lowerBound)...\(imageWidthRange.upperBound)")
        }
        return width
    }

    /// An optional `decider`, whose only value is `required`.
    static func parseDecider(_ raw: String?) throws -> Bool {
        guard let raw else { return false }
        guard raw == "required" else {
            throw SceneHeaderError.decider("'\(raw)' is not 'required'")
        }
        return true
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

    /// `- name: tap at X,Y` | `drag from X,Y radius R` | `hold at X,Y for MS` |
    /// `grid CxR from X,Y to X,Y`.
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
        guard name != SceneControl.waitName else {
            throw SceneHeaderError.controls("'\(name)' is reserved for waiting a frame")
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
        case ("grid", 6) where words[2] == "from" && words[4] == "to":
            gesture = try parseGrid(size: words[1], from: words[3], to: words[5], name: name)
        default:
            throw SceneHeaderError.controls(
                "'\(line)' is not 'tap at X,Y', 'drag from X,Y radius R', 'hold at X,Y for MS' "
                    + "or 'grid CxR from X,Y to X,Y'")
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

    /// A `CxR` board between its top-left `from` and bottom-right `to` corners.
    private static func parseGrid(size: String, from: String, to: String, name: String) throws -> SceneGesture {
        let dims = size.lowercased().split(separator: "x").map { Int($0) }
        guard dims.count == 2, let cols = dims[0], let rows = dims[1],
              (1...maxGridColumns).contains(cols), (1...maxGridRows).contains(rows) else {
            throw SceneHeaderError.controls(
                "'\(name)' grid size '\(size)' is not CxR with 1...\(maxGridColumns) columns "
                    + "and 1...\(maxGridRows) rows")
        }
        let topLeft = try fractionPoint(from, name: name)
        let bottomRight = try fractionPoint(to, name: name)
        guard bottomRight.x > topLeft.x, bottomRight.y > topLeft.y else {
            throw SceneHeaderError.controls("'\(name)' grid must run from its top-left to its bottom-right corner")
        }
        return .grid(cols: cols, rows: rows, x0: topLeft.x, y0: topLeft.y, x1: bottomRight.x, y1: bottomRight.y)
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
