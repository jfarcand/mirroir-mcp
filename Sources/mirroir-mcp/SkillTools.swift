// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers skill-related MCP tools: list_skills, get_skill.
// ABOUTME: Handles YAML and SKILL.md skill discovery, header parsing, and environment variable substitution.

import Foundation
import HelperLib

extension MirroirMCP {
    /// Register list_skills and get_skill. get_skill marks the skill's start screen
    /// on `session`, which save_compiled fingerprints the compiled file with.
    static func registerSkillTools(
        server: MCPServer, registry: TargetRegistry, session: CompilationSession
    ) {
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

                        // Read before the AI runs step 1: the screen this skill starts from.
                        markSkillStart(skillPath: path, content: content,
                                       session: session, target: registry.activeTarget)

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

    /// Matches `${VAR_NAME}` and `${VAR_NAME:-default_value}`.
    static let envPlaceholderPattern =
        "\\$\\{([A-Za-z_][A-Za-z0-9_]*)(?::-((?:[^}]|\\}(?!\\}))*?))?\\}"

    /// The `${VAR}` placeholder of `source` whose environment value is exactly `value`,
    /// or nil: the inverse of `substituteEnvVars` for one skill's value. An AI sees a
    /// skill with its variables resolved, so a value it records (a user name, a password)
    /// is stored as its placeholder and stays out of the compiled file. Only a whole
    /// value is matched (a short value such as `on` must not rewrite the inside of
    /// `Done`), and only a variable set in the environment: a default is written in the
    /// skill itself, and mapping every label equal to it would tie unrelated steps to it.
    static func envPlaceholder(resolvingTo value: String, in source: String) -> String? {
        guard !value.isEmpty,
              let regex = try? NSRegularExpression(pattern: envPlaceholderPattern) else {
            return nil
        }
        let env = ProcessInfo.processInfo.environment
        let range = NSRange(source.startIndex..., in: source)
        for match in regex.matches(in: source, range: range) {
            guard let fullRange = Range(match.range, in: source),
                  let nameRange = Range(match.range(at: 1), in: source),
                  env[String(source[nameRange])] == value else { continue }
            return String(source[fullRange])
        }
        return nil
    }

    /// Replace ${VAR} and ${VAR:-default} placeholders with environment variable values.
    /// When a default is specified via `:-`, it is used if the env var is unset.
    /// Unresolved variables without defaults are left as-is so the AI can flag them.
    static func substituteEnvVars(in text: String) -> String {
        var result = text
        let env = ProcessInfo.processInfo.environment

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: envPlaceholderPattern)
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
    /// Supports both .yaml and .md extensions. When both exist, .md takes precedence.
    /// Returns (resolvedPath, ambiguousMatches). If resolvedPath is non-nil, it's the unique match.
    /// If ambiguousMatches is non-empty, multiple files matched the basename.
    /// The CLI runners resolve with `RunnerSkillResolver`, over the same copies.
    static func resolveSkill(
        name: String,
        dirs: [String]
    ) -> (path: String?, ambiguous: [String]) {
        // Phase 1: exact relative path, .md across dirs first, then .yaml
        if let exact = exactSkillCopies(name: name, dirs: dirs).first {
            return (exact, [])
        }
        // Phase 2: basename across all directories, one match per skill path
        let groups = basenameSkillGroups(name: name, dirs: dirs, sameExtensionOnly: false)
        if groups.count > 1 {
            return (nil, groups.map(\.relPath))
        }
        return (groups.first?.paths.first, [])
    }

    /// The files an exact relative skill name points at, in the order resolution weighs
    /// them: every .md (nearer directory first), then every .yaml. A name given with its
    /// extension points at that file only.
    static func exactSkillCopies(name: String, dirs: [String]) -> [String] {
        let candidates: [String]
        if name.hasSuffix(".yaml") || name.hasSuffix(".md") {
            candidates = [name]
        } else {
            candidates = [name + ".md", name + ".yaml"]
        }
        return candidates.flatMap { candidate in dirs.map { $0 + "/" + candidate } }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Every skill whose file name matches the basename of `name`, one entry per path
    /// under the skill dir, each with its copies nearer directory first and .md before
    /// .yaml within one: a project-local copy overrides a global one, as
    /// `discoverSkills` lists them. With `sameExtensionOnly`, a name given with its
    /// extension matches only files of that extension.
    static func basenameSkillGroups(
        name: String, dirs: [String], sameExtensionOnly: Bool
    ) -> [(relPath: String, paths: [String])] {
        let fileName = (name as NSString).lastPathComponent
        let hasExtension = name.hasSuffix(".yaml") || name.hasSuffix(".md")
        let targetStem = hasExtension ? (fileName as NSString).deletingPathExtension : fileName
        let wantedExtension = (name as NSString).pathExtension

        var fullStems: [String] = []
        var groups: [String: (relPath: String, paths: [String])] = [:]
        for dir in dirs {
            for relPath in findSkillFiles(in: dir) {
                guard skillStem((relPath as NSString).lastPathComponent) == targetStem else { continue }
                if sameExtensionOnly, hasExtension,
                   (relPath as NSString).pathExtension != wantedExtension { continue }
                let fullStem = skillStem(relPath)
                if groups[fullStem] == nil {
                    fullStems.append(fullStem)
                    groups[fullStem] = (relPath, [])
                }
                groups[fullStem]?.paths.append(dir + "/" + relPath)
            }
        }
        return fullStems.compactMap { groups[$0] }
    }

    /// Check compilation status for a skill file and return a status string.
    /// Used by get_skill to inform the AI whether compilation is needed.
    /// Only checks version and source hash — dimension staleness is deferred to the
    /// test runner which has actual window dimensions from the active target.
    static func compilationStatus(for skillPath: String) -> String {
        guard let compiled = try? CompiledSkillIO.load(for: skillPath) else {
            return "[Not compiled \u{2014} use record_step after each step to compile]"
        }

        if let reason = CompiledSkillIO.sourceStaleness(compiled: compiled, skillPath: skillPath) {
            return "[Compiled: stale \u{2014} \(reason)]"
        }

        return "[Compiled: fresh]"
    }
}
