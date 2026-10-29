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
    /// Skill variant from the `kind:` header. "game" marks a model-interpreted
    /// scene skill that is never compiled to a .compiled.json and never replayed
    /// by the runner; empty for an ordinary, compilable/replayable skill.
    let kind: String
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
    case longPress(label: String, durationMs: Int?)
    case drag(fromLabel: String, toLabel: String)
    case switchTarget(TargetSelector)
    case skipped(stepType: String, reason: String)
    /// A step the parser could not turn into an action: an unknown verb or a
    /// malformed value. A skill holding one is refused before it runs.
    case invalid(stepType: String, reason: String)

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
        case .longPress: return "long_press"
        case .drag: return "drag"
        case .switchTarget: return "target"
        case .skipped(let stepType, _): return stepType
        case .invalid(let stepType, _): return stepType
        }
    }

    /// The step type when this is an AI-only step (`verify`, `remember`, ...), which
    /// only an AI client can evaluate; nil for every step the CLI runs itself.
    var aiOnlyStepType: String? {
        guard case .skipped(let stepType, _) = self,
              SkillParser.aiOnlyStepTypes.contains(stepType) else { return nil }
        return stepType
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
        case .longPress(let label, _): return label
        case .drag(let fromLabel, _): return fromLabel
        case .switchTarget(let selector): return selector.labelValue
        case .skipped, .invalid: return nil
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
        case .longPress(let label, _): return "long_press: \"\(label)\""
        case .drag(let from, let to): return "drag: \"\(from)\" -> \"\(to)\""
        case .switchTarget(let selector): return "target: \(selector.displayName)"
        case .skipped(let type, _): return "\(type) (skipped)"
        case .invalid(let type, _): return "\(type) (invalid)"
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
        let kind = headerKind(from: content)

        return SkillDefinition(
            name: header.name,
            description: header.description,
            filePath: filePath,
            steps: steps,
            targets: targets,
            kind: kind
        )
    }

    /// Extract the `kind:` header field (e.g. "game"), scanning the header
    /// prefix the same way name/description are read so it works for both
    /// SKILL.md front matter and legacy YAML skills. Empty when absent.
    static func headerKind(from content: String) -> String {
        for line in content.components(separatedBy: .newlines).prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("kind:") {
                return MirroirMCP.extractYAMLValue(from: trimmed, key: "kind")
            }
        }
        return ""
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

        // Parse "key: value" format. A bare word that is not a known keyword
        // is not an action this runner can perform.
        guard let colonIndex = trimmed.firstIndex(of: ":") else {
            return .invalid(stepType: trimmed, reason: "unknown step type")
        }
        let key = String(trimmed[trimmed.startIndex..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
        let rawValue = String(trimmed[trimmed.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespaces)
        return parseStep(key: key, rawValue: rawValue)
    }

    /// Why a step whose type no skill step has (e.g. a tool such as press_back) is invalid.
    static let unknownStepTypeReason = "unknown step type"

    /// Step types only an AI can interpret. `mirroir test` reports each one not
    /// evaluated, so a skill holding one does not pass.
    static let aiOnlyStepTypes: Set<String> = ["remember", "condition", "repeat", "verify", "summarize"]

    /// Parse one step from its type key and raw value, the two halves of
    /// `key: value`. Also rebuilds a step from a compiled step's type and label.
    static func parseStep(key: String, rawValue: String) -> SkillStep {
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
        case "long_press":
            return parseLongPress(value)
        case "drag":
            return parseDrag(value)
        case "target", "switch_target":
            switch TargetSelector.parse(rawValue) {
            case .success(let selector): return .switchTarget(selector)
            case .failure(let error):
                return .invalid(stepType: key, reason: error.localizedDescription)
            }
        case "measure":
            return parseMeasure(value)
        // AI-only steps that cannot run deterministically
        case _ where aiOnlyStepTypes.contains(key):
            return .skipped(stepType: key,
                            reason: "AI-only step — requires human interpretation")
        default:
            return .invalid(stepType: key, reason: unknownStepTypeReason)
        }
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
