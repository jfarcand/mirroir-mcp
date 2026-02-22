// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Parses skill YAML files into structured SkillDefinition with typed steps.
// ABOUTME: Uses regex-based parsing (no Yams dependency) reusing helpers from SkillTools.

import Foundation
import HelperLib

/// A parsed skill ready for execution.
struct SkillDefinition {
    let name: String
    let description: String
    let filePath: String
    let steps: [SkillStep]
    /// Target names declared in the skill header (for multi-target skills).
    let targets: [String]
}

/// A single executable step within a skill.
enum SkillStep {
    case launch(appName: String)
    case tap(label: String)
    case type(text: String)
    case pressKey(keyName: String, modifiers: [String])
    case swipe(direction: String)
    case waitFor(label: String, timeoutSeconds: Int?)
    case assertVisible(label: String)
    case assertNotVisible(label: String)
    case screenshot(label: String)
    case home
    case openURL(url: String)
    case shake
    case scrollTo(label: String, direction: String, maxScrolls: Int)
    case resetApp(appName: String)
    case setNetwork(mode: String)
    indirect case measure(name: String, action: SkillStep, until: String, maxSeconds: Double?)
    case switchTarget(name: String)
    case skipped(stepType: String, reason: String)

    /// The step type as a YAML key string (e.g. "tap", "wait_for", "launch").
    var typeKey: String {
        switch self {
        case .launch: return "launch"
        case .tap: return "tap"
        case .type: return "type"
        case .pressKey: return "press_key"
        case .swipe: return "swipe"
        case .waitFor: return "wait_for"
        case .assertVisible: return "assert_visible"
        case .assertNotVisible: return "assert_not_visible"
        case .screenshot: return "screenshot"
        case .home: return "home"
        case .openURL: return "open_url"
        case .shake: return "shake"
        case .scrollTo: return "scroll_to"
        case .resetApp: return "reset_app"
        case .setNetwork: return "set_network"
        case .measure: return "measure"
        case .switchTarget: return "target"
        case .skipped(let stepType, _): return stepType
        }
    }

    /// The primary label/value associated with this step, if any.
    var labelValue: String? {
        switch self {
        case .launch(let name): return name
        case .tap(let label): return label
        case .type(let text): return text
        case .pressKey(let key, _): return key
        case .swipe(let dir): return dir
        case .waitFor(let label, _): return label
        case .assertVisible(let label): return label
        case .assertNotVisible(let label): return label
        case .screenshot(let label): return label
        case .home: return nil
        case .openURL(let url): return url
        case .shake: return nil
        case .scrollTo(let label, _, _): return label
        case .resetApp(let name): return name
        case .setNetwork(let mode): return mode
        case .measure(let name, _, _, _): return name
        case .switchTarget(let name): return name
        case .skipped: return nil
        }
    }

    /// Human-readable description for reporting.
    var displayName: String {
        switch self {
        case .launch(let name): return "launch: \"\(name)\""
        case .tap(let label): return "tap: \"\(label)\""
        case .type(let text): return "type: \"\(text)\""
        case .pressKey(let key, let mods):
            if mods.isEmpty { return "press_key: \"\(key)\"" }
            return "press_key: \"\(key)\" [\(mods.joined(separator: ", "))]"
        case .swipe(let dir): return "swipe: \"\(dir)\""
        case .waitFor(let label, _): return "wait_for: \"\(label)\""
        case .assertVisible(let label): return "assert_visible: \"\(label)\""
        case .assertNotVisible(let label): return "assert_not_visible: \"\(label)\""
        case .screenshot(let label): return "screenshot: \"\(label)\""
        case .home: return "home"
        case .openURL(let url): return "open_url: \"\(url)\""
        case .shake: return "shake"
        case .scrollTo(let label, _, _): return "scroll_to: \"\(label)\""
        case .resetApp(let name): return "reset_app: \"\(name)\""
        case .setNetwork(let mode): return "set_network: \"\(mode)\""
        case .measure(let name, _, _, _): return "measure: \"\(name)\""
        case .switchTarget(let name): return "target: \"\(name)\""
        case .skipped(let type, _): return "\(type) (skipped)"
        }
    }
}

/// Parses skill YAML content into structured definitions.
enum SkillParser {

    /// Parse a skill file at the given path.
    /// Returns the parsed definition or throws on file read / parse errors.
    static func parse(filePath: String) throws -> SkillDefinition {
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        let substituted = MirroirMCP.substituteEnvVars(in: content)
        return parse(content: substituted, filePath: filePath)
    }

    /// Parse skill YAML content string.
    static func parse(content: String, filePath: String = "<inline>") -> SkillDefinition {
        let fallbackName = (filePath as NSString).lastPathComponent
            .replacingOccurrences(of: ".yaml", with: "")
        let header = MirroirMCP.extractSkillHeader(
            from: content, fallbackName: fallbackName, source: "")

        let steps = parseSteps(from: content)
        let targets = parseTargets(from: content)

        return SkillDefinition(
            name: header.name,
            description: header.description,
            filePath: filePath,
            steps: steps,
            targets: targets
        )
    }

    /// Extract target names from the `targets:` header block.
    /// Returns an empty array if no `targets:` block is found.
    static func parseTargets(from content: String) -> [String] {
        let lines = content.components(separatedBy: .newlines)
        var inTargets = false
        var targets: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "targets:" {
                inTargets = true
                continue
            }

            guard inTargets else { continue }

            // Target entries are list items: "- iphone"
            guard trimmed.hasPrefix("- ") else {
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty {
                    break
                }
                continue
            }

            let name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                targets.append(stripQuotes(name))
            }
        }

        return targets
    }

    /// Extract steps from the YAML content.
    /// Steps appear after a `steps:` line, each prefixed with `- key: "value"` or `- key`.
    static func parseSteps(from content: String) -> [SkillStep] {
        let lines = content.components(separatedBy: .newlines)
        var inSteps = false
        var steps: [SkillStep] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "steps:" {
                inSteps = true
                continue
            }

            guard inSteps else { continue }

            // Steps are list items starting with "- "
            guard trimmed.hasPrefix("- ") else {
                // A non-indented non-list line after steps: means we left the steps block
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty {
                    break
                }
                continue
            }

            let stepContent = String(trimmed.dropFirst(2))
            if let step = parseStep(stepContent) {
                steps.append(step)
            }
        }

        return steps
    }

    /// Parse a single step string like `tap: "General"` or `home`.
    static func parseStep(_ raw: String) -> SkillStep? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Check for bare keywords (no colon)
        if trimmed == "home" || trimmed == "press_home" {
            return .home
        }
        if trimmed == "shake" {
            return .shake
        }

        // Parse "key: value" format
        guard let colonIndex = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[trimmed.startIndex..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
        let rawValue = String(trimmed[trimmed.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespaces)
        let value = stripQuotes(rawValue)

        switch key {
        case "launch":
            return .launch(appName: value)
        case "tap":
            return .tap(label: value)
        case "type":
            return .type(text: value)
        case "press_key":
            return parsePressKey(value)
        case "swipe":
            return .swipe(direction: value)
        case "wait_for":
            return parseWaitFor(value)
        case "assert_visible":
            return .assertVisible(label: value)
        case "assert_not_visible":
            return .assertNotVisible(label: value)
        case "screenshot":
            return .screenshot(label: value)
        case "home", "press_home":
            return .home
        case "open_url":
            return .openURL(url: value)
        case "shake":
            return .shake
        case "scroll_to":
            return .scrollTo(label: value, direction: "up", maxScrolls: EnvConfig.defaultScrollMaxAttempts)
        case "reset_app":
            return .resetApp(appName: value)
        case "set_network":
            return .setNetwork(mode: value)
        case "target":
            return .switchTarget(name: value)
        case "measure":
            return parseMeasure(value)
        // AI-only steps that cannot run deterministically
        case "remember", "condition", "repeat", "verify", "summarize":
            return .skipped(stepType: key,
                            reason: "AI-only step — requires human interpretation")
        default:
            return .skipped(stepType: key,
                            reason: "Unknown step type")
        }
    }

    /// Parse a press_key value which may include modifiers.
    /// Formats: `"return"`, `"l" modifiers: ["command"]`, `"l+command"`
    private static func parsePressKey(_ value: String) -> SkillStep {
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

        // Check for inline modifiers: "key+mod1+mod2"
        if value.contains("+") {
            let parts = value.split(separator: "+").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            let keyName = parts[0]
            let modifiers = Array(parts.dropFirst())
            return .pressKey(keyName: keyName, modifiers: modifiers)
        }

        return .pressKey(keyName: value, modifiers: [])
    }

    /// Parse a wait_for value which may include a timeout.
    /// Formats: `"General"`, `"General" timeout: 30`
    private static func parseWaitFor(_ value: String) -> SkillStep {
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

    /// Parse a measure step value.
    /// Format: `{ tap: "Login", until: "Dashboard", max: 5, name: "login_time" }`
    private static func parseMeasure(_ value: String) -> SkillStep {
        var inner = value
        // Strip surrounding braces if present
        if inner.hasPrefix("{") && inner.hasSuffix("}") {
            inner = String(inner.dropFirst().dropLast())
        }

        // Extract components separated by commas
        let parts = inner.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

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

    /// Strip surrounding quotes from a value string.
    static func stripQuotes(_ value: String) -> String {
        var result = value
        if (result.hasPrefix("\"") && result.hasSuffix("\"")) ||
           (result.hasPrefix("'") && result.hasSuffix("'")) {
            result = String(result.dropFirst().dropLast())
        }
        return result
    }
}
