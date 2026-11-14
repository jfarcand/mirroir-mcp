/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Parses YAML skill step blocks into a structured RawStep tree.
// ABOUTME: Handles simple steps, conditions (if_visible/then/else), and repeat blocks.

import Foundation

/// A raw step from YAML, preserving nesting structure for conditions/repeats.
enum RawStep {
    case simple(key: String, value: String)
    case condition(ifVisible: String, thenSteps: [RawStep], elseSteps: [RawStep])
    case `repeat`(whileVisible: String, max: Int, steps: [RawStep])
}

/// Parses YAML step blocks into `RawStep` values.
enum MigrateStepParser {

    /// Extract raw steps from YAML lines, preserving condition/repeat structure.
    /// Only recognizes the top-level `steps:` keyword (at indent 0 or the file's header level).
    /// Nested `steps:` inside repeat blocks are collected as-is for sub-parsing.
    static func extractRawSteps(from lines: [String]) -> [RawStep] {
        var inSteps = false
        var stepLines: [String] = []
        var stepsIndent = -1

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count

            // Only match the top-level `steps:` (non-indented or at the header level)
            if trimmed == "steps:" && !inSteps {
                inSteps = true
                stepsIndent = indent
                continue
            }

            // Skip nested `steps:` that are deeper than the top-level one
            if inSteps && trimmed == "steps:" && indent > stepsIndent {
                stepLines.append(line)
                continue
            }

            if inSteps {
                // A non-indented, non-empty line after steps: means we left the steps block
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty
                    && !trimmed.hasPrefix("#") {
                    break
                }
                stepLines.append(line)
            }
        }

        return parseStepsBlock(stepLines, baseIndent: detectBaseIndent(stepLines))
    }

    /// Detect the indentation level of the first list item in a block.
    static func detectBaseIndent(_ lines: [String]) -> Int {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                let leadingSpaces = line.prefix(while: { $0 == " " }).count
                return leadingSpaces
            }
        }
        return 2
    }

    /// Parse a block of step lines into RawStep values.
    static func parseStepsBlock(_ lines: [String], baseIndent: Int) -> [RawStep] {
        var steps: [RawStep] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard trimmed.hasPrefix("- ") else {
                i += 1
                continue
            }

            let stepContent = String(trimmed.dropFirst(2))

            // Check for condition
            if stepContent.trimmingCharacters(in: .whitespaces) == "condition:" {
                let (condition, consumed) = parseConditionBlock(lines: lines, startIndex: i + 1, baseIndent: baseIndent)
                steps.append(condition)
                i += 1 + consumed
                continue
            }

            // Check for repeat
            if stepContent.trimmingCharacters(in: .whitespaces) == "repeat:" {
                let (repeatStep, consumed) = parseRepeatBlock(lines: lines, startIndex: i + 1, baseIndent: baseIndent)
                steps.append(repeatStep)
                i += 1 + consumed
                continue
            }

            // Simple step: "key: value" or bare keyword
            let parsed = parseSimpleStep(stepContent)
            steps.append(parsed)
            i += 1
        }

        return steps
    }

    /// Parse a simple step string like `launch: "Mail"` or `home`.
    static func parseSimpleStep(_ raw: String) -> RawStep {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // Bare keywords
        if trimmed == "home" || trimmed == "press_home" {
            return .simple(key: "home", value: "")
        }
        if trimmed == "shake" {
            return .simple(key: "shake", value: "")
        }

        // "key: value" format
        guard let colonIndex = trimmed.firstIndex(of: ":") else {
            return .simple(key: trimmed, value: "")
        }

        let key = String(trimmed[trimmed.startIndex..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
        let rawValue = String(trimmed[trimmed.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespaces)
        let value = SkillParser.stripQuotes(rawValue)

        // Handle press_home: true as a bare home step
        if key == "press_home" {
            return .simple(key: "home", value: "")
        }

        return .simple(key: key, value: value)
    }

    /// Parse a condition block starting after `- condition:`.
    /// Returns the parsed condition and how many lines were consumed.
    /// Only recognizes `if_visible:`, `then:`, `else:` at the condition's own keyword
    /// indentation level, so nested conditions don't confuse the outer parser.
    static func parseConditionBlock(
        lines: [String], startIndex: Int, baseIndent: Int
    ) -> (RawStep, Int) {
        var ifVisible = ""
        var thenLines: [String] = []
        var elseLines: [String] = []
        var inThen = false
        var inElse = false
        var consumed = 0
        // The keyword indent level is detected from the first keyword (if_visible:)
        var keywordIndent: Int?

        for j in startIndex..<lines.count {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count

            // Stop if we hit a line at or below the base indent that's a new list item
            if indent <= baseIndent && trimmed.hasPrefix("- ") {
                break
            }

            consumed += 1

            // Detect keyword indent from the first meaningful line
            if keywordIndent == nil && !trimmed.isEmpty {
                keywordIndent = indent
            }

            // Only recognize condition keywords at the expected indent level
            let isAtKeywordLevel = (keywordIndent != nil && indent == keywordIndent)

            if isAtKeywordLevel && trimmed.hasPrefix("if_visible:") {
                ifVisible = SkillParser.stripQuotes(
                    MirroirMCP.extractYAMLValue(from: trimmed, key: "if_visible"))
            } else if isAtKeywordLevel && trimmed == "then:" {
                inThen = true
                inElse = false
            } else if isAtKeywordLevel && trimmed == "else:" {
                inThen = false
                inElse = true
            } else if inThen {
                thenLines.append(line)
            } else if inElse {
                elseLines.append(line)
            }
        }

        let thenSteps = parseStepsBlock(thenLines, baseIndent: detectBaseIndent(thenLines))
        let elseSteps = parseStepsBlock(elseLines, baseIndent: detectBaseIndent(elseLines))

        return (.condition(ifVisible: ifVisible, thenSteps: thenSteps, elseSteps: elseSteps), consumed)
    }

    /// Parse a repeat block starting after `- repeat:`.
    /// Returns the parsed repeat and how many lines were consumed.
    /// Only recognizes `while_visible:`, `max:`, `steps:` at the repeat's own keyword
    /// indentation level.
    static func parseRepeatBlock(
        lines: [String], startIndex: Int, baseIndent: Int
    ) -> (RawStep, Int) {
        var whileVisible = ""
        var maxCount = 10
        var stepLines: [String] = []
        var inSteps = false
        var consumed = 0
        var keywordIndent: Int?

        for j in startIndex..<lines.count {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count

            if indent <= baseIndent && trimmed.hasPrefix("- ") {
                break
            }

            consumed += 1

            if keywordIndent == nil && !trimmed.isEmpty {
                keywordIndent = indent
            }

            let isAtKeywordLevel = (keywordIndent != nil && indent == keywordIndent)

            if isAtKeywordLevel && trimmed.hasPrefix("while_visible:") {
                whileVisible = SkillParser.stripQuotes(
                    MirroirMCP.extractYAMLValue(from: trimmed, key: "while_visible"))
            } else if isAtKeywordLevel && trimmed.hasPrefix("max:") {
                let maxStr = MirroirMCP.extractYAMLValue(from: trimmed, key: "max")
                maxCount = Int(maxStr) ?? 10
            } else if isAtKeywordLevel && trimmed == "steps:" {
                inSteps = true
            } else if inSteps {
                stepLines.append(line)
            }
        }

        let innerSteps = parseStepsBlock(stepLines, baseIndent: detectBaseIndent(stepLines))
        return (.repeat(whileVisible: whileVisible, max: maxCount, steps: innerSteps), consumed)
    }
}
