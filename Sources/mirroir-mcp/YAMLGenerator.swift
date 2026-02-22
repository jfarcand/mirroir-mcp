// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Converts recorded user interactions into skill YAML format.
// ABOUTME: Produces YAML compatible with the skill parser and test runner.

import Foundation

/// Generates skill YAML from a sequence of recorded events.
/// Produces output compatible with SkillParser and the `mirroir test` runner.
enum YAMLGenerator {

    /// Generate a complete skill YAML document from recorded events.
    /// - Parameters:
    ///   - events: The recorded user interactions
    ///   - name: Skill name for the YAML header
    ///   - description: Skill description
    ///   - appName: Optional app name for the header
    /// - Returns: The YAML string ready to write to a file
    static func generate(
        events: [RecordedEvent],
        name: String,
        description: String,
        appName: String?
    ) -> String {
        var lines: [String] = []

        // Header
        lines.append("name: \(name)")
        if let app = appName {
            lines.append("app: \(app)")
        }
        lines.append("description: \(description)")
        lines.append("")
        lines.append("steps:")

        // Convert each event to a YAML step
        for event in events {
            let stepLines = generateStep(event.kind)
            for line in stepLines {
                lines.append("  \(line)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Generate YAML lines for a single event.
    /// Returns one or more lines (the primary step plus optional comments).
    static func generateStep(_ kind: RecordedEventKind) -> [String] {
        switch kind {
        case .tap(let x, let y, let label):
            return generateTap(x: x, y: y, label: label)

        case .swipe(let direction):
            return ["- swipe: \"\(direction)\""]

        case .longPress(let x, let y, let label, let durationMs):
            return generateLongPress(x: x, y: y, label: label, durationMs: durationMs)

        case .type(let text):
            return generateType(text: text)

        case .pressKey(let keyName, let modifiers):
            return generatePressKey(keyName: keyName, modifiers: modifiers)
        }
    }

    // MARK: - Step Generators

    private static func generateTap(x: Double, y: Double, label: String?) -> [String] {
        if let label = label {
            return ["- tap: \"\(escapeYAML(label))\"  # at (\(Int(x)), \(Int(y)))"]
        }
        // No OCR label found — output coordinate comment for user to replace
        return ["- tap: \"FIXME\"  # at (\(Int(x)), \(Int(y))) — replace with visible text label"]
    }

    private static func generateLongPress(x: Double, y: Double, label: String?,
                                           durationMs: Int) -> [String] {
        let coord = "# at (\(Int(x)), \(Int(y))), held \(durationMs)ms"
        if let label = label {
            return ["- long_press: \"\(escapeYAML(label))\"  \(coord)"]
        }
        return ["- long_press: \"FIXME\"  \(coord) — replace with visible text label"]
    }

    private static func generateType(text: String) -> [String] {
        // Use block scalar for multi-line text, inline for single-line
        if text.contains("\n") {
            var lines = ["- type: |"]
            for line in text.components(separatedBy: "\n") {
                lines.append("    \(line)")
            }
            return lines
        }
        return ["- type: \"\(escapeYAML(text))\""]
    }

    private static func generatePressKey(keyName: String, modifiers: [String]) -> [String] {
        if modifiers.isEmpty {
            return ["- press_key: \"\(keyName)\""]
        }
        let allParts = [keyName] + modifiers
        return ["- press_key: \"\(allParts.joined(separator: "+"))\""]
    }

    // MARK: - YAML Escaping

    /// Escape special characters for YAML double-quoted strings.
    static func escapeYAML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
