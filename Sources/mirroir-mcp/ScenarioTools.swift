// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers scenario-related MCP tools: list_scenarios, get_scenario.
// ABOUTME: Handles YAML and SKILL.md scenario discovery, header parsing, and environment variable substitution.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerScenarioTools(server: MCPServer) {
        // list_scenarios — discover available scenarios from config directories
        server.registerTool(MCPToolDefinition(
            name: "list_scenarios",
            description: """
                List all available test scenarios from both project-local and global \
                config directories. Returns scenario names and descriptions extracted \
                from YAML files in <cwd>/.mirroir-mcp/scenarios/ and \
                ~/.mirroir-mcp/scenarios/. Project-local scenarios with the \
                same filename override global ones.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { _ in
                let scenarios = discoverScenarios()
                if scenarios.isEmpty {
                    return .text(
                        "No scenarios found.\n" +
                        "Place .yaml or .md files in <cwd>/.mirroir-mcp/scenarios/ or " +
                        "~/.mirroir-mcp/scenarios/")
                }

                var lines: [String] = []
                for scenario in scenarios {
                    let desc = scenario.description.isEmpty
                        ? "(no description)"
                        : scenario.description
                    lines.append("- \(scenario.name): \(desc)  [\(scenario.source)]")
                }
                return .text(lines.joined(separator: "\n"))
            }
        ))

        // get_scenario — read a scenario file with environment variable substitution
        server.registerTool(MCPToolDefinition(
            name: "get_scenario",
            description: """
                Read a scenario YAML file by name and return its contents with \
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
                            "Scenario name or path (e.g. 'login-flow' or 'slack/send-message')"),
                    ])
                ]),
                "required": .array([.string("name")]),
            ],
            handler: { args in
                guard let name = args["name"]?.asString() else {
                    return .error("Missing required parameter: name (string)")
                }

                let dirs = PermissionPolicy.scenarioDirs
                let (resolvedPath, ambiguous) = resolveScenario(name: name, dirs: dirs)

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
                            "Failed to read scenario at \(path): \(error.localizedDescription)")
                    }
                }

                if !ambiguous.isEmpty {
                    let matches = ambiguous.map { "  - \($0)" }.joined(separator: "\n")
                    return .error(
                        "Ambiguous scenario name '\(name)'. Multiple matches found:\n\(matches)\n" +
                        "Use the full path (e.g. 'apps/slack/\(name)') to disambiguate.")
                }

                // Not found — show available scenarios to help the user
                let scenarios = discoverScenarios()
                if scenarios.isEmpty {
                    let searchedDirs = dirs.joined(separator: ", ")
                    return .error(
                        "Scenario '\(name)' not found. No scenarios installed.\n" +
                        "Searched: \(searchedDirs)\n" +
                        "Install scenarios: https://github.com/jfarcand/mirroir-scenarios")
                }

                let available = scenarios.map { "  - \($0.name)" }.joined(separator: "\n")
                return .error(
                    "Scenario '\(name)' not found. Available scenarios:\n\(available)")
            }
        ))
    }

    // MARK: Scenario Helpers

    /// Metadata extracted from a scenario YAML file header.
    struct ScenarioInfo {
        let name: String
        let description: String
        let source: String
    }

    /// Recursively scan scenario directories and return metadata for each scenario file found.
    /// Supports both .yaml and .md (SKILL.md) formats. When both exist with the same stem,
    /// the .md file takes precedence. Project-local files override global files with the same
    /// relative path.
    static func discoverScenarios() -> [ScenarioInfo] {
        let dirs = PermissionPolicy.scenarioDirs
        var seenStems = Set<String>()
        var results: [ScenarioInfo] = []

        for dir in dirs {
            let source = dir.hasPrefix(PermissionPolicy.globalConfigDir) ? "global" : "local"
            for relPath in findScenarioFiles(in: dir) {
                let stem = scenarioStem(relPath)
                if seenStems.contains(stem) { continue }
                seenStems.insert(stem)

                let filePath = dir + "/" + relPath
                let info = extractScenarioHeader(from: filePath, source: source)
                results.append(info)
            }
        }

        return results
    }

    /// Recursively find all scenario files (.md and .yaml) under a directory.
    /// Returns relative paths sorted with .md files before .yaml files for the same stem,
    /// ensuring .md takes precedence during discovery.
    static func findScenarioFiles(in baseDir: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: baseDir) else { return [] }

        var relPaths: [String] = []
        while let entry = enumerator.nextObject() as? String {
            if entry.hasSuffix(".yaml") || entry.hasSuffix(".md") {
                relPaths.append(entry)
            }
        }

        // Sort with .md before .yaml for the same stem, so .md wins during dedup
        return relPaths.sorted { a, b in
            let stemA = scenarioStem(a)
            let stemB = scenarioStem(b)
            if stemA == stemB {
                // .md comes first
                return a.hasSuffix(".md")
            }
            return a < b
        }
    }

    /// Recursively find all .yaml files under a directory, returning relative paths sorted.
    static func findYAMLFiles(in baseDir: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: baseDir) else { return [] }

        var relPaths: [String] = []
        while let entry = enumerator.nextObject() as? String {
            if entry.hasSuffix(".yaml") {
                relPaths.append(entry)
            }
        }
        return relPaths.sorted()
    }

    /// Extract the stem (path without extension) from a scenario relative path.
    /// Used for deduplication when both .md and .yaml exist.
    static func scenarioStem(_ relPath: String) -> String {
        if relPath.hasSuffix(".yaml") {
            return String(relPath.dropLast(5))
        }
        if relPath.hasSuffix(".md") {
            return String(relPath.dropLast(3))
        }
        return relPath
    }

    /// Extract name and description from a scenario file (YAML or SKILL.md).
    /// For .md files, parses the YAML front matter. For .yaml files, looks for
    /// `name:` and `description:` keys in the file header.
    static func extractScenarioHeader(from path: String, source: String) -> ScenarioInfo {
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
            DebugLog.log("ScenarioTools", "Failed to read scenario header at \(path): \(error)")
            return ScenarioInfo(name: fallbackName, description: "", source: source)
        }

        if path.hasSuffix(".md") {
            let header = SkillMdParser.parseHeader(content: content, fallbackName: fallbackName)
            return ScenarioInfo(
                name: header.name, description: header.description, source: source)
        }

        return extractScenarioHeader(from: content, fallbackName: fallbackName, source: source)
    }

    /// Parse scenario header from YAML content string.
    static func extractScenarioHeader(
        from content: String,
        fallbackName: String,
        source: String
    ) -> ScenarioInfo {
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

        return ScenarioInfo(name: name, description: description, source: source)
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
            DebugLog.log("ScenarioTools", "Regex compilation failed: \(error)")
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

    /// Resolve a scenario name to a file path, supporting both exact relative paths and basename lookup.
    /// Supports both .yaml and .md extensions. When both exist, .md takes precedence (unless yamlOnly).
    /// When `yamlOnly` is true, only .yaml files are considered — used by the deterministic test runner
    /// and compiler which cannot execute natural-language markdown.
    /// Returns (resolvedPath, ambiguousMatches). If resolvedPath is non-nil, it's the unique match.
    /// If ambiguousMatches is non-empty, multiple files matched the basename.
    static func resolveScenario(
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
            // When yamlOnly, only search YAML files; otherwise search all scenario files
            let files = yamlOnly ? findYAMLFiles(in: dir) : findScenarioFiles(in: dir)
            for relPath in files {
                let basename = (relPath as NSString).lastPathComponent
                let baseStem = scenarioStem(basename)
                if baseStem == targetStem {
                    let fullStem = scenarioStem(relPath)
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

    /// Check compilation status for a scenario file and return a status string.
    /// Used by get_scenario to inform the AI whether compilation is needed.
    /// Only checks version and source hash — dimension staleness is deferred to the
    /// test runner which has actual window dimensions from the active target.
    static func compilationStatus(for scenarioPath: String) -> String {
        guard let compiled = try? CompiledScenarioIO.load(for: scenarioPath) else {
            return "[Not compiled \u{2014} use record_step after each step to compile]"
        }

        // Version check
        if compiled.version != CompiledScenario.currentVersion {
            return "[Compiled: stale \u{2014} compiled version \(compiled.version) != current \(CompiledScenario.currentVersion)]"
        }

        // Source hash check
        if let currentHash = try? CompiledScenarioIO.sha256(of: scenarioPath),
           currentHash != compiled.source.sha256 {
            return "[Compiled: stale \u{2014} source file has changed since compilation]"
        }

        return "[Compiled: fresh]"
    }
}
