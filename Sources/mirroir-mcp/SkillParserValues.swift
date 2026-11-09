// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Parsers for the step values that carry more than one field: press_key, wait_for, long_press, drag, measure, scene.
// ABOUTME: Each reads the value half of a `key: value` step line, as SkillParser.parseStep hands it over.

import Foundation

extension SkillParser {

    /// Parse a press_key value which may include modifiers.
    /// Formats: `"return"`, `"l" modifiers: ["command"]`, `"l+command"`
    static func parsePressKey(_ value: String) -> SkillStep {
        // Check for dict-style modifiers: "key" modifiers: ["mod1", "mod2"]
        if let modRange = value.range(of: #" modifiers: \["#, options: .regularExpression) {
            let keyName = stripQuotes(
                String(value[value.startIndex..<modRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            )
            // Extract the bracket contents: everything between [ and ]
            let afterBracket = value[modRange.upperBound...]
            if let closeBracket = afterBracket.firstIndex(of: "]") {
                let bracketContent = String(afterBracket[afterBracket.startIndex..<closeBracket])
                let modifiers = bracketContent
                    .split(separator: ",")
                    .map { stripQuotes(String($0).trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
                return .pressKey(keyName: keyName, modifiers: modifiers)
            }
        }

        // The "+" key itself with inline modifiers: "++mod1+mod2"
        if value.hasPrefix("++") {
            let modifiers = value.dropFirst(2).split(separator: "+").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            return .pressKey(keyName: "+", modifiers: modifiers)
        }

        // Check for inline modifiers: "key+mod1+mod2"
        if value.contains("+") {
            let parts = value.split(separator: "+").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            // A value made only of "+" splits into nothing: the key is "+" itself.
            guard let keyName = parts.first, !keyName.isEmpty else {
                return .pressKey(keyName: value, modifiers: [])
            }
            let modifiers = Array(parts.dropFirst())
            return .pressKey(keyName: keyName, modifiers: modifiers)
        }

        return .pressKey(keyName: value, modifiers: [])
    }

    /// Parse a wait_for value which may include a timeout.
    /// Formats: `"General"`, `"General" timeout: 30`
    static func parseWaitFor(_ value: String) -> SkillStep {
        // Check for timeout suffix: "label" timeout: 30
        if let timeoutRange = value.range(of: #" timeout: "#, options: .regularExpression) {
            let label = stripQuotes(
                String(value[value.startIndex..<timeoutRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            )
            let timeoutStr = String(value[timeoutRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            let timeout = Int(timeoutStr)
            return .waitFor(label: label, timeoutSeconds: timeout)
        }

        return .waitFor(label: value, timeoutSeconds: nil)
    }

    /// Parse a long_press value which may include a duration.
    /// Formats: `"Element"`, `"Element" duration: 1000`
    static func parseLongPress(_ value: String) -> SkillStep {
        if let durationRange = value.range(of: #" duration: "#, options: .regularExpression) {
            let label = stripQuotes(
                String(value[value.startIndex..<durationRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            )
            let durationStr = String(value[durationRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            let duration = Int(durationStr)
            return .longPress(label: label, durationMs: duration)
        }
        return .longPress(label: value, durationMs: nil)
    }

    /// Parse a drag value with from/to labels.
    /// Format: `{ from: "Source", to: "Target" }`
    static func parseDrag(_ value: String) -> SkillStep {
        var fromLabel = ""
        var toLabel = ""

        for entry in inlineMapEntries(value) {
            guard let val = entry.value.map(stripQuotes) else { continue }
            switch entry.key {
            case "from": fromLabel = val
            case "to": toLabel = val
            default: break
            }
        }

        if fromLabel.isEmpty && toLabel.isEmpty {
            return .skipped(stepType: "drag", reason: "Missing from/to labels")
        }
        return .drag(fromLabel: fromLabel, toLabel: toLabel)
    }

    /// Parse a measure step value.
    /// Format: `{ tap: "Login", until: "Dashboard", max: 5, name: "login_time" }`
    static func parseMeasure(_ value: String) -> SkillStep {
        var actionStep: SkillStep?
        var until = ""
        var maxSeconds: Double?
        var name = "measure"

        for entry in inlineMapEntries(value) {
            guard let val = entry.value else { continue }
            let stripped = stripQuotes(val)

            switch entry.key {
            case "until":
                until = stripped
            case "max":
                maxSeconds = Double(stripped)
            case "name":
                name = stripped
            default:
                // Try to parse as an action step (e.g., tap: "Login")
                if let step = parseStep("\(entry.key): \(val)") {
                    actionStep = step
                }
            }
        }

        let action = actionStep ?? .skipped(stepType: "measure",
                                             reason: "No action found in measure step")
        return .measure(name: name, action: action, until: until, maxSeconds: maxSeconds)
    }

    /// The entries of an inline `{ key: value, ... }` map, in order. The braces
    /// are optional; commas inside quoted values do not split. An entry with no
    /// `:` comes back with a nil value, for the caller to refuse or skip.
    static func inlineMapEntries(_ value: String) -> [(key: String, value: String?)] {
        var inner = value.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("{") && inner.hasSuffix("}") {
            inner = String(inner.dropFirst().dropLast())
        }
        return TargetSelector.splitTopLevel(inner).map { part in
            guard let colonIdx = part.firstIndex(of: ":") else { return (part, nil) }
            let key = String(part[part.startIndex..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            let val = String(part[part.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
            return (key, val)
        }
    }

    /// Parse a scene step value, its budget written flat beside the skill.
    /// Format: `{ skill: "name", max_frames: 6, max_tokens: 150000, max_seconds: 60,
    /// decider: "/path/to/picker --flag" }`. Every budget field is required and
    /// positive; `decider` is optional; any other key is refused.
    static func parseScene(_ value: String) -> SkillStep {
        var skill: String?
        var decider: String?
        var budgetEntries: [String] = []
        for entry in inlineMapEntries(value) {
            guard let val = entry.value else {
                return .invalid(stepType: "scene", reason: "'\(entry.key)' is not key: value")
            }
            if entry.key == "skill" {
                skill = stripQuotes(val)
            } else if entry.key == "decider" {
                let command = stripQuotes(val).trimmingCharacters(in: .whitespaces)
                guard !command.isEmpty else {
                    return .invalid(stepType: "scene", reason: "decider names no command")
                }
                decider = command
            } else {
                budgetEntries.append("\(entry.key): \(val)")
            }
        }
        guard let skill, !skill.isEmpty else {
            return .invalid(stepType: "scene", reason: "names no skill")
        }
        do {
            let budget = try SceneHeaderParser.parseBudget(budgetEntries.joined(separator: ", "))
            return .scene(skill: skill, budget: budget, decider: decider)
        } catch {
            return .invalid(stepType: "scene", reason: error.localizedDescription)
        }
    }
}

/// A tap step that names a point instead of text: `tap: @324,113`, in the points
/// describe_screen reports. Controls without readable text (a search field that
/// is showing a query, an icon) can only be named this way. The `@` keeps it
/// apart from text that reads like coordinates, such as a price of "12,41".
enum TapStepPoint {
    static let prefix = "@"

    /// The point `value` names, or nil when it is ordinary text.
    static func parse(_ value: String) -> (x: Double, y: Double)? {
        guard value.hasPrefix(prefix) else { return nil }
        let parts = value.dropFirst(prefix.count).split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (x, y)
    }

    /// The step value for a point: whole points, the fraction dropped.
    /// Formatted, not converted: `Int(_:)` traps on a value no integer holds.
    static func format(x: Double, y: Double) -> String {
        let whole = { (value: Double) in String(format: "%.0f", value.rounded(.towardZero)) }
        return "\(prefix)\(whole(x)),\(whole(y))"
    }
}
