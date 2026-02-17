// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Parses scenario YAML files into structured ScenarioDefinition with typed steps.
// ABOUTME: Uses regex-based parsing (no Yams dependency) reusing helpers from ScenarioTools.

import Foundation

/// A parsed scenario ready for execution.
struct ScenarioDefinition {
    let name: String
    let description: String
    let filePath: String
    let steps: [ScenarioStep]
}

/// A single executable step within a scenario.
enum ScenarioStep {
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
    case skipped(stepType: String, reason: String)

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
        case .skipped(let type, _): return "\(type) (skipped)"
        }
    }
}

/// Parses scenario YAML content into structured definitions.
enum ScenarioParser {

    /// Parse a scenario file at the given path.
    /// Returns the parsed definition or throws on file read / parse errors.
    static func parse(filePath: String) throws -> ScenarioDefinition {
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        let substituted = IPhoneMirroirMCP.substituteEnvVars(in: content)
        return parse(content: substituted, filePath: filePath)
    }

    /// Parse scenario YAML content string.
    static func parse(content: String, filePath: String = "<inline>") -> ScenarioDefinition {
        let fallbackName = (filePath as NSString).lastPathComponent
            .replacingOccurrences(of: ".yaml", with: "")
        let header = IPhoneMirroirMCP.extractScenarioHeader(
            from: content, fallbackName: fallbackName, source: "")

        let steps = parseSteps(from: content)

        return ScenarioDefinition(
            name: header.name,
            description: header.description,
            filePath: filePath,
            steps: steps
        )
    }

    /// Extract steps from the YAML content.
    /// Steps appear after a `steps:` line, each prefixed with `- key: "value"` or `- key`.
    static func parseSteps(from content: String) -> [ScenarioStep] {
        let lines = content.components(separatedBy: .newlines)
        var inSteps = false
        var steps: [ScenarioStep] = []

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
    static func parseStep(_ raw: String) -> ScenarioStep? {
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
    private static func parsePressKey(_ value: String) -> ScenarioStep {
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
    private static func parseWaitFor(_ value: String) -> ScenarioStep {
        // Simple case: just a label
        return .waitFor(label: value, timeoutSeconds: nil)
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
