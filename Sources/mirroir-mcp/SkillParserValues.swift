// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Parsers for the step values that carry more than one field: press_key, wait_for, long_press, drag, measure.
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
        var inner = value
        if inner.hasPrefix("{") && inner.hasSuffix("}") {
            inner = String(inner.dropFirst().dropLast())
        }

        let parts = TargetSelector.splitTopLevel(inner)

        var fromLabel = ""
        var toLabel = ""

        for part in parts {
            guard let colonIdx = part.firstIndex(of: ":") else { continue }
            let key = String(part[part.startIndex..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            let val = stripQuotes(
                String(part[part.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)
            )
            switch key {
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
        var inner = value
        // Strip surrounding braces if present
        if inner.hasPrefix("{") && inner.hasSuffix("}") {
            inner = String(inner.dropFirst().dropLast())
        }

        // Extract components separated by commas
        let parts = TargetSelector.splitTopLevel(inner)

        var actionStep: SkillStep?
        var until = ""
        var maxSeconds: Double?
        var name = "measure"

        for part in parts {
            guard let colonIdx = part.firstIndex(of: ":") else { continue }
            let key = String(part[part.startIndex..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            let val = String(part[part.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
            let stripped = stripQuotes(val)

            switch key {
            case "until":
                until = stripped
            case "max":
                maxSeconds = Double(stripped)
            case "name":
                name = stripped
            default:
                // Try to parse as an action step (e.g., tap: "Login")
                if let step = parseStep(part) {
                    actionStep = step
                }
            }
        }

        let action = actionStep ?? .skipped(stepType: "measure",
                                             reason: "No action found in measure step")
        return .measure(name: name, action: action, until: until, maxSeconds: maxSeconds)
    }
}
