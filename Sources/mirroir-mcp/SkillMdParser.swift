// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Parses SKILL.md scenario files (YAML front matter + markdown body).
// ABOUTME: Extracts structured header metadata and the freeform markdown body for AI execution.

import Foundation

/// Parses SKILL.md files: YAML front matter delimited by `---` lines, followed by a markdown body.
/// The front matter contains structured metadata (name, app, tags, etc.), while the body contains
/// natural-language steps that an AI agent interprets and executes via MCP tools.
enum SkillMdParser {
    /// Current format version for SKILL.md files.
    static let currentVersion = 1

    /// Metadata extracted from SKILL.md front matter.
    struct SkillHeader {
        let version: Int
        let name: String
        let app: String
        let description: String
        let iosMin: String
        let locale: String
        let tags: [String]
    }

    /// Parse YAML front matter from a SKILL.md file.
    /// Front matter is delimited by opening and closing `---` lines.
    /// Falls back to defaults for missing fields.
    static func parseHeader(content: String, fallbackName: String) -> SkillHeader {
        let frontMatter = extractFrontMatter(content: content)
        guard !frontMatter.isEmpty else {
            // No front matter — derive description from body
            let body = parseBody(content: content)
            let description = extractFirstParagraph(from: body)
            return SkillHeader(
                version: currentVersion,
                name: fallbackName,
                app: "",
                description: description,
                iosMin: "",
                locale: "",
                tags: []
            )
        }

        let version = extractIntValue(from: frontMatter, key: "version") ?? currentVersion
        let name = extractStringValue(from: frontMatter, key: "name") ?? fallbackName
        let app = extractStringValue(from: frontMatter, key: "app") ?? ""
        let iosMin = extractStringValue(from: frontMatter, key: "ios_min") ?? ""
        let locale = extractStringValue(from: frontMatter, key: "locale") ?? ""
        let tags = extractArrayValue(from: frontMatter, key: "tags")

        // Description: try front matter first, fall back to first paragraph of body
        let fmDescription = extractStringValue(from: frontMatter, key: "description") ?? ""
        let description: String
        if fmDescription.isEmpty {
            let body = parseBody(content: content)
            description = extractFirstParagraph(from: body)
        } else {
            description = fmDescription
        }

        return SkillHeader(
            version: version,
            name: name,
            app: app,
            description: description,
            iosMin: iosMin,
            locale: locale,
            tags: tags
        )
    }

    /// Extract the markdown body (everything after the closing `---`).
    /// If no front matter delimiters are found, the entire content is the body.
    static func parseBody(content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var foundFirstDelimiter = false
        var bodyStartIndex: Int?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !foundFirstDelimiter {
                    foundFirstDelimiter = true
                } else {
                    bodyStartIndex = index + 1
                    break
                }
            }
        }

        guard let startIndex = bodyStartIndex, startIndex < lines.count else {
            // No front matter found — entire content is the body
            if !foundFirstDelimiter {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }

        let bodyLines = Array(lines[startIndex...])
        let body = bodyLines.joined(separator: "\n")
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Front Matter Extraction

    /// Extract the raw front matter string between `---` delimiters.
    private static func extractFrontMatter(content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var foundFirstDelimiter = false
        var frontMatterLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !foundFirstDelimiter {
                    foundFirstDelimiter = true
                    continue
                } else {
                    break
                }
            }
            if foundFirstDelimiter {
                frontMatterLines.append(line)
            }
        }

        guard foundFirstDelimiter else { return "" }
        return frontMatterLines.joined(separator: "\n")
    }

    /// Extract a string value from YAML front matter using simple key: value parsing.
    private static func extractStringValue(from frontMatter: String, key: String) -> String? {
        let lines = frontMatter.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                let value = MirroirMCP.extractYAMLValue(from: trimmed, key: key)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Extract an integer value from YAML front matter.
    private static func extractIntValue(from frontMatter: String, key: String) -> Int? {
        guard let strValue = extractStringValue(from: frontMatter, key: key) else {
            return nil
        }
        return Int(strValue)
    }

    /// Extract a YAML inline array value like `["tag1", "tag2"]`.
    private static func extractArrayValue(from frontMatter: String, key: String) -> [String] {
        let lines = frontMatter.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                let value = MirroirMCP.extractYAMLValue(from: trimmed, key: key)
                return parseInlineArray(value)
            }
        }
        return []
    }

    /// Parse a YAML inline array string like `["a", "b", "c"]` into a Swift array.
    private static func parseInlineArray(_ raw: String) -> [String] {
        var value = raw.trimmingCharacters(in: .whitespaces)
        // Strip surrounding brackets
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        } else {
            return value.isEmpty ? [] : [value]
        }

        return value.components(separatedBy: ",").compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            // Strip quotes
            if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
               (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
                return String(trimmed.dropFirst().dropLast())
            }
            return trimmed
        }
    }

    /// Extract the first paragraph from a markdown body as a description.
    /// A paragraph ends at the first blank line or heading.
    private static func extractFirstParagraph(from body: String) -> String {
        let lines = body.components(separatedBy: .newlines)
        var paragraphLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Stop at blank line or heading
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if !paragraphLines.isEmpty { break }
                continue
            }
            paragraphLines.append(trimmed)
        }

        return paragraphLines.joined(separator: " ")
    }
}
