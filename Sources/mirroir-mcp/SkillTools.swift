// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers skill-related MCP tools: list_skills, get_skill.
// ABOUTME: Handles YAML and SKILL.md skill discovery, header parsing, and environment variable substitution.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerSkillTools(server: MCPServer) {
        // list_skills — discover available skills from config directories
        server.registerTool(MCPToolDefinition(
            name: "list_skills",
            description: """
                List all available test skills from both project-local and global \
                config directories. Returns skill names and descriptions extracted \
                from YAML files in <cwd>/.mirroir-mcp/skills/ and \
                ~/.mirroir-mcp/skills/. Project-local skills with the \
                same filename override global ones.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { _ in
                let skills = discoverSkills()
                if skills.isEmpty {
                    return .text(
                        "No skills found.\n" +
                        "Place .yaml or .md files in <cwd>/.mirroir-mcp/skills/ or " +
                        "~/.mirroir-mcp/skills/")
                }

                var lines: [String] = []
                for skill in skills {
                    let desc = skill.description.isEmpty
                        ? "(no description)"
                        : skill.description
                    lines.append("- \(skill.name): \(desc)  [\(skill.source)]")
                }
                return .text(lines.joined(separator: "\n"))
            }
        ))

        // get_skill — read a skill file with environment variable substitution
        server.registerTool(MCPToolDefinition(
            name: "get_skill",
            description: """
                Read a skill YAML file by name and return its contents with \
                ${VAR} placeholders resolved from environment variables. Looks in \
                project-local directory first, then global. The AI interprets the \
                YAML steps and executes them using existing MCP tools. \
                Supports both YAML (.yaml) and SKILL.md (.md) formats.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Skill name or path (e.g. 'login-flow' or 'slack/send-message')"),
                    ])
                ]),
                "required": .array([.string("name")]),
            ],
            handler: { args in
                guard let name = args["name"]?.asString() else {
                    return .error("Missing required parameter: name (string)")
                }

                let dirs = PermissionPolicy.skillDirs
                let (resolvedPath, ambiguous) = resolveSkill(name: name, dirs: dirs)

                if let path = resolvedPath {
                    do {
                        var content = try String(contentsOfFile: path, encoding: .utf8)
                        content = substituteEnvVars(in: content)

                        // Append compilation status for AI decision-making
                        let status = compilationStatus(for: path)
                        content += "\n\n\(status)"

                        return .text(content)
                    } catch {
                        return .error(
                            "Failed to read skill at \(path): \(error.localizedDescription)")
                    }
                }

                if !ambiguous.isEmpty {
                    let matches = ambiguous.map { "  - \($0)" }.joined(separator: "\n")
                    return .error(
                        "Ambiguous skill name '\(name)'. Multiple matches found:\n\(matches)\n" +
                        "Use the full path (e.g. 'apps/slack/\(name)') to disambiguate.")
                }

                // Not found — show available skills to help the user
                let skills = discoverSkills()
                if skills.isEmpty {
                    let searchedDirs = dirs.joined(separator: ", ")
                    return .error(
                        "Skill '\(name)' not found. No skills installed.\n" +
                        "Searched: \(searchedDirs)\n" +
                        "Install skills: https://github.com/jfarcand/mirroir-skills")
                }

                let available = skills.map { "  - \($0.name)" }.joined(separator: "\n")
                return .error(
                    "Skill '\(name)' not found. Available skills:\n\(available)")
            }
        ))
    }

    // MARK: Skill Helpers

    /// Metadata extracted from a skill YAML file header.
    struct SkillInfo {
        let name: String
        let description: String
        let source: String
    }

    /// Recursively scan skill directories and return metadata for each skill file found.
    /// Supports both .yaml and .md (SKILL.md) formats. When both exist with the same stem,
    /// the .md file takes precedence. Project-local files override global files with the same
    /// relative path.
    static func discoverSkills() -> [SkillInfo] {
        let dirs = PermissionPolicy.skillDirs
        var seenStems = Set<String>()
        var results: [SkillInfo] = []

        for dir in dirs {
            let source = dir.hasPrefix(PermissionPolicy.globalConfigDir) ? "global" : "local"
            for relPath in findSkillFiles(in: dir) {
                let stem = skillStem(relPath)
                if seenStems.contains(stem) { continue }
                seenStems.insert(stem)

                let filePath = dir + "/" + relPath
                let info = extractSkillHeader(from: filePath, source: source)
                results.append(info)
            }
        }

        return results
    }

    /// Recursively find all skill files (.md and .yaml) under a directory.
    /// Returns relative paths sorted with .md files before .yaml files for the same stem,
    /// ensuring .md takes precedence during discovery.
    static func findSkillFiles(in baseDir: String) -> [String] {
        let results = findFiles(in: baseDir) {
            $0.hasSuffix(".yaml") || $0.hasSuffix(".md")
        }

        // Sort with .md before .yaml for the same stem, so .md wins during dedup
        return results.sorted { a, b in
            let stemA = skillStem(a)
            let stemB = skillStem(b)
            if stemA == stemB {
                // .md comes first
                return a.hasSuffix(".md")
            }
            return a < b
        }
    }

    /// Recursively find all .yaml files under a directory, returning relative paths sorted.
    static func findYAMLFiles(in baseDir: String) -> [String] {
        findFiles(in: baseDir) { $0.hasSuffix(".yaml") }
    }

    /// Recursively find all .md files under a directory, returning relative paths sorted.
    static func findMDFiles(in baseDir: String) -> [String] {
        findFiles(in: baseDir) { $0.hasSuffix(".md") }
    }

    /// Shared file enumeration: recursively scan a directory and return relative paths
    /// matching the given predicate, sorted alphabetically.
    private static func findFiles(
        in baseDir: String,
        matching predicate: (String) -> Bool
    ) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: baseDir) else { return [] }
        var relPaths: [String] = []
        while let entry = enumerator.nextObject() as? String {
            if predicate(entry) { relPaths.append(entry) }
        }
        return relPaths.sorted()
    }

    /// Extract the stem (path without extension) from a skill relative path.
    /// Used for deduplication when both .md and .yaml exist.
    static func skillStem(_ relPath: String) -> String {
        if relPath.hasSuffix(".yaml") {
            return String(relPath.dropLast(5))
        }
        if relPath.hasSuffix(".md") {
            return String(relPath.dropLast(3))
        }
        return relPath
    }

    /// Extract name and description from a skill file (YAML or SKILL.md).
    /// For .md files, parses the YAML front matter. For .yaml files, looks for
    /// `name:` and `description:` keys in the file header.
    static func extractSkillHeader(from path: String, source: String) -> SkillInfo {
        let filename = (path as NSString).lastPathComponent
        let fallbackName: String
        if filename.hasSuffix(".md") {
            fallbackName = String(filename.dropLast(3))
        } else {
            fallbackName = filename.replacingOccurrences(of: ".yaml", with: "")
        }

        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            DebugLog.log("SkillTools", "Failed to read skill header at \(path): \(error)")
            return SkillInfo(name: fallbackName, description: "", source: source)
        }

        if path.hasSuffix(".md") {
            let header = SkillMdParser.parseHeader(content: content, fallbackName: fallbackName)
            return SkillInfo(
                name: header.name, description: header.description, source: source)
        }

        return extractSkillHeader(from: content, fallbackName: fallbackName, source: source)
    }

    /// Parse skill header from YAML content string.
    static func extractSkillHeader(
        from content: String,
        fallbackName: String,
        source: String
    ) -> SkillInfo {
        var name = fallbackName
        var description = ""

        let lines = content.components(separatedBy: .newlines)
        let headerLines = Array(lines.prefix(20))
        var collectingDescription = false

        for line in headerLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // If we're collecting block scalar continuation lines
            if collectingDescription {
                // Continuation lines must be indented (start with whitespace)
                // and not be a new top-level key
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    let continuation = trimmed
                    if !continuation.isEmpty {
                        if description.isEmpty {
                            description = continuation
                        } else {
                            description += " " + continuation
                        }
                    }
                    continue
                } else {
                    // No longer indented — stop collecting
                    collectingDescription = false
                }
            }

            if trimmed.hasPrefix("name:") {
                name = extractYAMLValue(from: trimmed, key: "name")
            } else if trimmed.hasPrefix("description:") {
                let value = extractYAMLValue(from: trimmed, key: "description")
                if value == ">" || value == "|" || value == ">-" || value == "|-" {
                    // Block scalar indicator — collect continuation lines
                    collectingDescription = true
                    description = ""
                } else {
                    description = value
                }
            }
        }

        return SkillInfo(name: name, description: description, source: source)
    }

    /// Extract the value portion of a simple "key: value" YAML line, stripping quotes.
    static func extractYAMLValue(from line: String, key: String) -> String {
        let afterKey = line.dropFirst(key.count + 1) // drop "key:"
        var value = afterKey.trimmingCharacters(in: .whitespaces)
        // Strip surrounding quotes if present
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Replace ${VAR} and ${VAR:-default} placeholders with environment variable values.
    /// When a default is specified via `:-`, it is used if the env var is unset.
    /// Unresolved variables without defaults are left as-is so the AI can flag them.
    static func substituteEnvVars(in text: String) -> String {
        var result = text
        let env = ProcessInfo.processInfo.environment

        // Match ${VAR_NAME} and ${VAR_NAME:-default_value} patterns
        let pattern = "\\$\\{([A-Za-z_][A-Za-z0-9_]*)(?::-((?:[^}]|\\}(?!\\}))*?))?\\}"
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            DebugLog.log("SkillTools", "Regex compilation failed: \(error)")
            return result
        }

        let nsRange = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: nsRange)

        // Process matches in reverse order to preserve string indices
        for match in matches.reversed() {
            guard let varRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else {
                continue
            }
            let varName = String(result[varRange])

            if let value = env[varName] {
                result.replaceSubrange(fullRange, with: value)
            } else if match.range(at: 2).location != NSNotFound,
                      let defaultRange = Range(match.range(at: 2), in: result) {
                let defaultValue = String(result[defaultRange])
                result.replaceSubrange(fullRange, with: defaultValue)
            }
            // No env var and no default — leave as-is for the AI to flag
        }

        return result
    }

    /// Resolve a skill name to a file path, supporting both exact relative paths and basename lookup.
    /// Supports both .yaml and .md extensions. When both exist, .md takes precedence (unless yamlOnly).
    /// When `yamlOnly` is true, only .yaml files are considered — used by the deterministic test runner
    /// and compiler which cannot execute natural-language markdown.
    /// Returns (resolvedPath, ambiguousMatches). If resolvedPath is non-nil, it's the unique match.
    /// If ambiguousMatches is non-empty, multiple files matched the basename.
    static func resolveSkill(
        name: String,
        dirs: [String],
        yamlOnly: Bool = false
    ) -> (path: String?, ambiguous: [String]) {
        // Determine the stem and whether the user specified an extension
        let stem: String
        let hasExtension: Bool
        if name.hasSuffix(".yaml") {
            stem = String(name.dropLast(5))
            hasExtension = true
        } else if name.hasSuffix(".md") {
            stem = String(name.dropLast(3))
            hasExtension = true
        } else {
            stem = name
            hasExtension = false
        }

        // Phase 1: Try exact relative path match (project-local first)
        // When yamlOnly, only try .yaml; otherwise try .md first (preferred), then .yaml
        let candidates: [String]
        if hasExtension {
            candidates = [name]
        } else if yamlOnly {
            candidates = [stem + ".yaml"]
        } else {
            candidates = [stem + ".md", stem + ".yaml"]
        }

        for candidate in candidates {
            for dir in dirs {
                let path = dir + "/" + candidate
                if FileManager.default.fileExists(atPath: path) {
                    return (path, [])
                }
            }
        }

        // Phase 2: Try basename match across all directories
        // Deduplicate by stem so local overrides global and .md overrides .yaml
        let targetStem: String
        if hasExtension {
            targetStem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        } else {
            targetStem = (name as NSString).lastPathComponent
        }

        var seenStems = Set<String>()
        var matches: [String] = []

        for dir in dirs {
            // When yamlOnly, only search YAML files; otherwise search all skill files
            let files = yamlOnly ? findYAMLFiles(in: dir) : findSkillFiles(in: dir)
            for relPath in files {
                let basename = (relPath as NSString).lastPathComponent
                let baseStem = skillStem(basename)
                if baseStem == targetStem {
                    let fullStem = skillStem(relPath)
                    if seenStems.contains(fullStem) { continue }
                    seenStems.insert(fullStem)
                    matches.append(relPath)
                }
            }
        }

        if matches.count == 1 {
            // Unique stem match — find which dir it's in
            for dir in dirs {
                let candidate = dir + "/" + matches[0]
                if FileManager.default.fileExists(atPath: candidate) {
                    return (candidate, [])
                }
            }
        }

        if matches.count > 1 {
            return (nil, matches)
        }

        return (nil, [])
    }

    /// Check compilation status for a skill file and return a status string.
    /// Used by get_skill to inform the AI whether compilation is needed.
    /// Only checks version and source hash — dimension staleness is deferred to the
    /// test runner which has actual window dimensions from the active target.
    static func compilationStatus(for skillPath: String) -> String {
        guard let compiled = try? CompiledSkillIO.load(for: skillPath) else {
            return "[Not compiled \u{2014} use record_step after each step to compile]"
        }

        // Version check
        if compiled.version != CompiledSkill.currentVersion {
            return "[Compiled: stale \u{2014} compiled version \(compiled.version) != current \(CompiledSkill.currentVersion)]"
        }

        // Source hash check
        if let currentHash = try? CompiledSkillIO.sha256(of: skillPath),
           currentHash != compiled.source.sha256 {
            return "[Compiled: stale \u{2014} source file has changed since compilation]"
        }

        return "[Compiled: fresh]"
    }
}
