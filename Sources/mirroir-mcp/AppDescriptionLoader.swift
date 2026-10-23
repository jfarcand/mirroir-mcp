// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Discovers and loads APP.md files matching an app name from disk search paths.
// ABOUTME: Supports locale-specific descriptions and ${VAR} substitution in credentials.

import Foundation
import HelperLib

/// Discovers APP.md files on disk and matches them to app names.
/// Search paths follow the same convention as skills: project-local overrides global.
enum AppDescriptionLoader {

    /// Load an app description matching the given app name.
    ///
    /// When multiple APP.md files match (e.g. different locales), the first match
    /// from the highest-priority search path wins. Locale-specific files
    /// (matching the system locale) are preferred over locale-less files.
    ///
    /// - Parameter appName: The app name to match (case-insensitive, diacritics-insensitive).
    /// - Returns: The best matching AppDescription, or nil if no APP.md matches.
    static func load(appName: String) -> AppDescription? {
        let normalizedName = foldName(appName)
        var bestMatch: AppDescription?
        let systemLocale = Locale.current.identifier

        for dir in searchPaths() {
            let files = findAppFiles(in: dir)
            for filePath in files {
                guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
                    continue
                }
                guard let description = AppDescriptionParser.parse(content: content) else {
                    continue
                }
                guard foldName(description.appName) == normalizedName else {
                    continue
                }

                // Exact locale match takes highest priority — return immediately
                if let locale = description.locale,
                   locale.lowercased() == systemLocale.lowercased() {
                    DebugLog.log("app-desc",
                        "Loaded APP.md for '\(appName)' (locale=\(locale)) from \(filePath)")
                    return resolveVariables(in: description)
                }

                // First name-matched file is the fallback (locale-less preferred,
                // but locale-specific files also qualify when no locale-less exists)
                if bestMatch == nil {
                    bestMatch = description
                } else if bestMatch?.locale != nil && description.locale == nil {
                    // Locale-less file replaces a locale-specific fallback
                    bestMatch = description
                }
            }
        }

        if bestMatch != nil {
            DebugLog.log("app-desc", "Loaded APP.md for '\(appName)' (no locale)")
        }
        return bestMatch.map { resolveVariables(in: $0) }
    }

    /// Search paths for APP.md files, in resolution order.
    /// New `patterns/apps/` paths first; legacy `apps/` as fallback.
    static func searchPaths() -> [String] {
        let cwd = FileManager.default.currentDirectoryPath
        return PermissionPolicy.skillDirs + [
            // New structure: patterns/apps/
            cwd + "/../mirroir-skills/patterns/apps",
        ] + PermissionPolicy.skillDirs.map { $0 + "/patterns/apps" } + [
            // Legacy fallback: apps/
            cwd + "/../mirroir-skills/apps",
            cwd + "/../mirroir-skills",
        ]
    }

    // MARK: - Private

    /// Fold a name to lowercase ASCII for diacritics-insensitive comparison.
    /// "Santé" → "sante", "Météo" → "meteo".
    private static func foldName(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Recursively find all files named `APP.md` (case-insensitive) in a directory.
    /// Only matches files whose last path component is exactly "APP.md" (any case),
    /// not files like "install-app.md" that happen to end with "app.md".
    private static func findAppFiles(in baseDir: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: baseDir) else { return [] }
        var results: [String] = []
        while let entry = enumerator.nextObject() as? String {
            let filename = (entry as NSString).lastPathComponent.lowercased()
            if filename == "app.md" {
                results.append(baseDir + "/" + entry)
            }
        }
        return results.sorted()
    }

    /// Resolve ${VAR} and ${VAR:-default} placeholders in credential values.
    private static func resolveVariables(in description: AppDescription) -> AppDescription {
        guard !description.credentials.isEmpty else { return description }

        var resolved: [String: String] = [:]
        for (key, value) in description.credentials {
            resolved[key] = resolveEnvVars(in: value)
        }

        return AppDescription(
            appName: description.appName,
            schemaVersion: description.schemaVersion,
            locale: description.locale,
            archetype: description.archetype,
            playable: description.playable,
            resetBeforeExplore: description.resetBeforeExplore,
            obstacleMode: description.obstacleMode,
            context: description.context,
            obstacles: description.obstacles,
            skipElements: description.skipElements,
            credentials: resolved,
            hints: description.hints,
            tabs: description.tabs,
            tabLayout: description.tabLayout,
            deepTabs: description.deepTabs,
            simulator: description.simulator
        )
    }

    /// Resolve ${VAR} and ${VAR:-default} patterns in a string.
    private static func resolveEnvVars(in text: String) -> String {
        var result = text
        // Match ${VAR:-default} first, then ${VAR}
        let patterns = [
            (try? NSRegularExpression(pattern: #"\$\{(\w+):-([^}]*)\}"#)),
            (try? NSRegularExpression(pattern: #"\$\{(\w+)\}"#)),
        ]

        if let regex = patterns[0] {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: range)
            for match in matches.reversed() {
                guard let varRange = Range(match.range(at: 1), in: result),
                      let defaultRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let varName = String(result[varRange])
                let defaultValue = String(result[defaultRange])
                let value = ProcessInfo.processInfo.environment[varName] ?? defaultValue
                result.replaceSubrange(fullRange, with: value)
            }
        }

        if let regex = patterns[1] {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: range)
            for match in matches.reversed() {
                guard let varRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let varName = String(result[varRange])
                let value = ProcessInfo.processInfo.environment[varName] ?? ""
                result.replaceSubrange(fullRange, with: value)
            }
        }

        return result
    }
}
