// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Formats parsed YAML steps into natural-language markdown for SKILL.md output.
// ABOUTME: Converts RawStep trees into numbered step lists with proper indentation.

import Foundation

/// Formats `RawStep` values into numbered markdown lines for SKILL.md output.
enum MigrateStepFormatter {

    /// Convert a list of RawSteps to numbered markdown lines.
    static func convertSteps(_ steps: [RawStep], startNumber: Int, indent: Int) -> [String] {
        var lines: [String] = []
        var number = startNumber
        let prefix = String(repeating: " ", count: indent)

        for step in steps {
            switch step {
            case .simple(let key, let value):
                let text = formatSimpleStep(key: key, value: value)
                lines.append("\(prefix)\(number). \(text)")
                number += 1

            case .condition(let ifVisible, let thenSteps, let elseSteps):
                lines.append("\(prefix)\(number). If \"\(ifVisible)\" is visible:")
                let thenLines = convertSteps(thenSteps, startNumber: 1, indent: indent + 3)
                lines.append(contentsOf: thenLines)
                if !elseSteps.isEmpty {
                    lines.append("\(prefix)   Otherwise:")
                    let elseLines = convertSteps(elseSteps, startNumber: 1, indent: indent + 3)
                    lines.append(contentsOf: elseLines)
                }
                number += 1

            case .repeat(let whileVisible, let maxCount, let innerSteps):
                lines.append("\(prefix)\(number). Repeat while \"\(whileVisible)\" is visible (max \(maxCount)):")
                let innerLines = convertSteps(innerSteps, startNumber: 1, indent: indent + 3)
                lines.append(contentsOf: innerLines)
                number += 1
            }
        }

        return lines
    }

    /// Format a simple step into natural-language markdown.
    static func formatSimpleStep(key: String, value: String) -> String {
        switch key {
        case "launch":
            return "Launch **\(value)**"
        case "tap":
            return "Tap \"\(value)\""
        case "type":
            return "Type \"\(value)\""
        case "wait_for":
            return "Wait for \"\(value)\" to appear"
        case "assert_visible":
            return "Verify \"\(value)\" is visible"
        case "assert_not_visible":
            return "Verify \"\(value)\" is NOT visible"
        case "screenshot":
            return "Screenshot: \"\(value)\""
        case "press_key":
            return formatPressKey(value)
        case "home":
            return "Press Home"
        case "open_url":
            return "Open URL: \(value)"
        case "shake":
            return "Shake the device"
        case SkillParser.clearFieldKey:
            return "Clear the text field"
        case "scroll_to":
            return "Scroll until \"\(value)\" is visible"
        case "reset_app":
            return "Force-quit **\(value)**"
        case "set_network":
            return formatNetworkMode(value)
        case "target":
            return "Switch to target \"\(value)\""
        case "remember":
            return "Remember: \(value)"
        case "measure":
            return formatMeasure(value)
        default:
            // Unknown step — preserve as-is
            if value.isEmpty {
                return key
            }
            return "\(key): \"\(value)\""
        }
    }

    /// Format a press_key step value into natural language.
    /// Input: "return", "l+command", "escape"
    static func formatPressKey(_ value: String) -> String {
        if value.contains("+") {
            let parts = value.split(separator: "+").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            let keyName = parts[0]
            let modifiers = Array(parts.dropFirst())
            let modStr = modifiers.map { formatModifier($0) }.joined(separator: "+")
            return "Press **\(modStr)+\(keyName.capitalized)**"
        }
        return "Press **\(value.capitalized)**"
    }

    /// Format a modifier name to its display form.
    static func formatModifier(_ mod: String) -> String {
        switch mod.lowercased() {
        case "command": return "Cmd"
        case "shift": return "Shift"
        case "option": return "Option"
        case "control": return "Ctrl"
        default: return mod.capitalized
        }
    }

    /// Format a set_network mode to natural language.
    static func formatNetworkMode(_ mode: String) -> String {
        switch mode {
        case "airplane_on": return "Turn on Airplane Mode"
        case "airplane_off": return "Turn off Airplane Mode"
        case "wifi_on": return "Turn on Wi-Fi"
        case "wifi_off": return "Turn off Wi-Fi"
        case "cellular_on": return "Turn on Cellular"
        case "cellular_off": return "Turn off Cellular"
        default: return "Set network: \(mode)"
        }
    }

    /// Format a measure step value into natural language.
    /// Input might be `{ tap: "Login", until: "Dashboard", max: 5, name: "login_time" }`
    static func formatMeasure(_ value: String) -> String {
        var inner = value
        if inner.hasPrefix("{") && inner.hasSuffix("}") {
            inner = String(inner.dropFirst().dropLast())
        }

        let parts = inner.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        var action = ""
        var until = ""
        var maxSeconds = ""
        var name = ""

        for part in parts {
            guard let colonIdx = part.firstIndex(of: ":") else { continue }
            let key = String(part[part.startIndex..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            let val = SkillParser.stripQuotes(
                String(part[part.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces))

            switch key {
            case "until": until = val
            case "max": maxSeconds = val
            case "name": name = val
            default: action = "\(key) \"\(val)\""
            }
        }

        var result = "Measure"
        if !name.isEmpty { result += " (\(name))" }
        result += ": \(action)"
        if !until.isEmpty { result += " and wait for \"\(until)\"" }
        if !maxSeconds.isEmpty { result += " (max \(maxSeconds)s)" }
        return result
    }
}
