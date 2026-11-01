// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Discovers and loads .recipe.md files from disk search paths.
// ABOUTME: Follows the same resolution convention as ComponentLoader: project-local overrides global.

import Foundation
import HelperLib

/// Discovers and loads screen recipe definitions from .recipe.md files on disk.
/// Project-local files override global files with the same name.
enum RecipeLoader {

    /// Load all recipe definitions from disk search paths.
    static func loadAll() -> [ScreenRecipe] {
        loadFromDisk()
    }

    /// Search paths for screen pattern .recipe.md files, in resolution order.
    /// New `patterns/screens/` paths first; legacy `recipes/ios/` as fallback.
    static func searchPaths() -> [String] {
        let checkouts = PermissionPolicy.skillsCheckouts
        return [
            PermissionPolicy.localConfigDir + "/recipes",
            PermissionPolicy.globalConfigDir + "/recipes",
        ]
            // New structure: patterns/screens/
            + checkouts.map { $0 + "/patterns/screens" }
            // Legacy fallback: recipes/ios/
            + checkouts.map { $0 + "/recipes/ios" }
    }

    // MARK: - Private

    private static func loadFromDisk() -> [ScreenRecipe] {
        var seen = Set<String>()
        var recipes: [ScreenRecipe] = []

        for dir in searchPaths() {
            let files = findRecipeFiles(in: dir)
            if !files.isEmpty {
                DebugLog.log("recipes", "Found \(files.count) recipe files in \(dir)")
            }
            for filePath in files {
                guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
                    continue
                }
                guard let recipe = RecipeParser.parse(content: content) else {
                    continue
                }
                guard !seen.contains(recipe.name) else { continue }
                seen.insert(recipe.name)
                recipes.append(recipe)
            }
        }

        DebugLog.log("recipes", "Loaded \(recipes.count) recipes")
        return recipes
    }

    /// Find all `.recipe.md` files in a directory (non-recursive).
    private static func findRecipeFiles(in baseDir: String) -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: baseDir) else { return [] }
        return contents
            .filter { $0.hasSuffix(".recipe.md") }
            .sorted()
            .map { baseDir + "/" + $0 }
    }
}

/// Parses .recipe.md files into ScreenRecipe instances.
/// Pure transformation: all static methods, no stored state.
enum RecipeParser {

    /// Parse a .recipe.md file's content into a ScreenRecipe.
    static func parse(content: String) -> ScreenRecipe? {
        let (frontMatter, sections) = extractFrontMatterAndSections(content: content)

        guard let name = frontMatter["name"] else { return nil }
        let platform = frontMatter["platform"] ?? "ios"

        let description = sections["Description"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !description.isEmpty else { return nil }

        let required = parseComponentList(sections["Required Components"] ?? "")
        let supporting = parseComponentList(sections["Supporting Components"] ?? "")
        let forbidden = parseComponentList(sections["Forbidden Components"] ?? "")
        let navModel = parseNavigationModel(sections["Navigation Model"] ?? "")
        let hints = parseHints(sections["Exploration Hints"] ?? "")

        return ScreenRecipe(
            name: name,
            platform: platform,
            description: description,
            requiredComponents: Set(required),
            supportingComponents: Set(supporting),
            forbiddenComponents: Set(forbidden),
            navigationModel: navModel,
            explorationHints: hints
        )
    }

    // MARK: - Private Parsing Helpers

    /// Extract YAML front matter and markdown sections from content.
    private static func extractFrontMatterAndSections(
        content: String
    ) -> ([String: String], [String: String]) {
        var frontMatter: [String: String] = [:]
        var sections: [String: String] = [:]
        var currentSection: String?
        var currentBody: [String] = []
        var inFrontMatter = false
        var frontMatterDone = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "---" {
                if !frontMatterDone && !inFrontMatter {
                    inFrontMatter = true
                    continue
                } else if inFrontMatter {
                    inFrontMatter = false
                    frontMatterDone = true
                    continue
                }
            }

            if inFrontMatter {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    frontMatter[key] = value
                }
                continue
            }

            if trimmed.hasPrefix("## ") {
                if let section = currentSection {
                    sections[section] = currentBody.joined(separator: "\n")
                }
                currentSection = String(trimmed.dropFirst(3))
                currentBody = []
            } else if trimmed.hasPrefix("# ") {
                // H1 title — skip
            } else {
                currentBody.append(line)
            }
        }

        if let section = currentSection {
            sections[section] = currentBody.joined(separator: "\n")
        }

        return (frontMatter, sections)
    }

    /// Parse a bulleted list of component names.
    private static func parseComponentList(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parse the Navigation Model section's key-value pairs.
    private static func parseNavigationModel(_ text: String) -> RecipeNavigationModel {
        var kv: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            var stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("- ") { stripped = String(stripped.dropFirst(2)) }
            guard let colonIdx = stripped.firstIndex(of: ":") else { continue }
            let key = String(stripped[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(stripped[stripped.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
            kv[key] = value
        }

        return RecipeNavigationModel(
            type: kv["type"] ?? "drill-down",
            backtrack: kv["backtrack"] ?? "tap-back-chevron",
            scrollBehavior: kv["scroll_behavior"] ?? "finite",
            depthPattern: kv["depth_pattern"] ?? "linear",
            calibrationScrollLimit: kv["calibration_scroll_limit"].flatMap { Int($0) }
        )
    }

    /// Parse exploration hints as a list of strings.
    private static func parseHints(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
