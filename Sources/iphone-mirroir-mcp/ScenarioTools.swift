// ABOUTME: Registers scenario-related MCP tools: list_scenarios, get_scenario.
// ABOUTME: Handles YAML scenario discovery, header parsing, and environment variable substitution.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
    static func registerScenarioTools(server: MCPServer) {
        // list_scenarios — discover available YAML scenarios from config directories
        server.registerTool(MCPToolDefinition(
            name: "list_scenarios",
            description: """
                List all available test scenarios from both project-local and global \
                config directories. Returns scenario names and descriptions extracted \
                from YAML files in <cwd>/.iphone-mirroir-mcp/scenarios/ and \
                ~/.iphone-mirroir-mcp/scenarios/. Project-local scenarios with the \
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
                        "Place .yaml files in <cwd>/.iphone-mirroir-mcp/scenarios/ or " +
                        "~/.iphone-mirroir-mcp/scenarios/")
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
                YAML steps and executes them using existing MCP tools.
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

                let filename = name.hasSuffix(".yaml") ? name : name + ".yaml"
                let dirs = PermissionPolicy.scenarioDirs

                var filePath: String?
                for dir in dirs {
                    let candidate = dir + "/" + filename
                    if FileManager.default.fileExists(atPath: candidate) {
                        filePath = candidate
                        break
                    }
                }

                guard let resolvedPath = filePath else {
                    let searchedDirs = dirs.joined(separator: ", ")
                    return .error(
                        "Scenario '\(name)' not found. Searched: \(searchedDirs)")
                }

                do {
                    var content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
                    content = substituteEnvVars(in: content)
                    return .text(content)
                } catch {
                    return .error(
                        "Failed to read scenario at \(resolvedPath): \(error.localizedDescription)")
                }
            }
        ))
    }

    // MARK: Scenario Helpers

    /// Metadata extracted from a scenario YAML file header.
    private struct ScenarioInfo {
        let name: String
        let description: String
        let source: String
    }

    /// Recursively scan scenario directories and return metadata for each .yaml file found.
    /// Project-local files override global files with the same relative path.
    private static func discoverScenarios() -> [ScenarioInfo] {
        let dirs = PermissionPolicy.scenarioDirs
        var seenRelPaths = Set<String>()
        var results: [ScenarioInfo] = []

        for dir in dirs {
            let source = dir.hasPrefix(PermissionPolicy.globalConfigDir) ? "global" : "local"
            for relPath in findYAMLFiles(in: dir) {
                if seenRelPaths.contains(relPath) { continue }
                seenRelPaths.insert(relPath)

                let filePath = dir + "/" + relPath
                let info = extractScenarioHeader(from: filePath, source: source)
                results.append(info)
            }
        }

        return results
    }

    /// Recursively find all .yaml files under a directory, returning relative paths sorted.
    private static func findYAMLFiles(in baseDir: String) -> [String] {
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

    /// Extract name and description from the first lines of a YAML scenario file.
    /// Looks for `name:` and `description:` keys in the file header.
    private static func extractScenarioHeader(from path: String, source: String) -> ScenarioInfo {
        let fallbackName = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".yaml", with: "")

        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            DebugLog.log("ScenarioTools", "Failed to read scenario header at \(path): \(error)")
            return ScenarioInfo(name: fallbackName, description: "", source: source)
        }

        var name = fallbackName
        var description = ""

        for line in content.components(separatedBy: .newlines).prefix(10) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = extractYAMLValue(from: trimmed, key: "name")
            } else if trimmed.hasPrefix("description:") {
                description = extractYAMLValue(from: trimmed, key: "description")
            }
        }

        return ScenarioInfo(name: name, description: description, source: source)
    }

    /// Extract the value portion of a simple "key: value" YAML line, stripping quotes.
    private static func extractYAMLValue(from line: String, key: String) -> String {
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
    private static func substituteEnvVars(in text: String) -> String {
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
}
