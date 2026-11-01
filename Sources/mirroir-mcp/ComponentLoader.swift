// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Discovers and loads COMPONENT.md files from disk search paths.
// ABOUTME: Search paths follow the same convention as skill files: project-local overrides global.

import Foundation
import HelperLib

/// Discovers and loads component definitions from COMPONENT.md files on disk.
/// Project-local files override global files with the same name.
enum ComponentLoader {

    /// Load all component definitions from disk search paths.
    ///
    /// Project-local files override global files with the same name.
    ///
    /// - Returns: All component definitions found, deduplicated by name.
    static func loadAll() -> [ComponentDefinition] {
        loadFromDisk()
    }

    /// Search paths for element pattern .md files, in resolution order.
    /// New `patterns/elements/` paths are checked first; legacy `components/ios/` paths
    /// are kept as fallback for repos that haven't restructured yet.
    static func searchPaths() -> [URL] {
        let cwd = FileManager.default.currentDirectoryPath
        let home = ("~" as NSString).expandingTildeInPath
        let configDir = PermissionPolicy.configDirName

        let checkouts = PermissionPolicy.skillsCheckouts
        // Project-local overrides, then the new structure (patterns/elements/),
        // then the legacy fallback (components/ios/ and components/custom/).
        let paths = [cwd + "/" + configDir + "/components", home + "/" + configDir + "/components"]
            + checkouts.map { $0 + "/patterns/elements" }
            + checkouts.flatMap { [$0 + "/components/ios", $0 + "/components/custom"] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Private

    /// Load COMPONENT.md files from all search paths.
    /// Earlier paths take priority when names collide.
    private static func loadFromDisk() -> [ComponentDefinition] {
        var seen = Set<String>()
        var definitions: [ComponentDefinition] = []
        let cwd = FileManager.default.currentDirectoryPath

        for searchPath in searchPaths() {
            let files = findComponentFiles(in: searchPath)
            if !files.isEmpty {
                DebugLog.log("components", "Found \(files.count) files in \(searchPath.path)")
            }
            for fileURL in files {
                let stem = fileURL.deletingPathExtension().lastPathComponent

                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    continue
                }

                guard let definition = ComponentSkillParser.parseValidated(
                    content: content, fallbackName: stem
                ) else {
                    continue
                }
                // Skip non-component files (e.g. vision-indicators.md) that
                // parse without error but lack a Description section.
                guard !definition.description.isEmpty else { continue }
                // Dedup by component name (the identity) so earlier search
                // paths win on collision. Lookup and insert use the same key.
                guard !seen.contains(definition.name) else { continue }
                seen.insert(definition.name)
                definitions.append(definition)
            }
        }

        DebugLog.log("components", "Loaded \(definitions.count) definitions (cwd=\(cwd))")
        return definitions
    }

    /// A vision indicator mapping: suffix → OCR character.
    struct VisionIndicator: Sendable {
        let suffix: String
        let ocrChar: String
    }

    /// Load vision indicator mappings from `vision-indicators.md` in component search paths.
    /// Returns an empty array if no file is found.
    static func loadVisionIndicators() -> [VisionIndicator] {
        for searchPath in searchPaths() {
            let fileURL = searchPath.appendingPathComponent("vision-indicators.md")
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            return parseVisionIndicators(content: content)
        }
        return []
    }

    /// Parse the `## Indicators` section from a vision-indicators.md file.
    private static func parseVisionIndicators(content: String) -> [VisionIndicator] {
        var indicators: [VisionIndicator] = []
        var inSection = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## Indicators") {
                inSection = true
                continue
            }
            if trimmed.hasPrefix("##") && inSection {
                break
            }
            if inSection && trimmed.hasPrefix("- ") {
                let body = String(trimmed.dropFirst(2))
                let parts = body.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let suffix = parts[0].trimmingCharacters(in: .whitespaces)
                let ocrChar = parts[1].trimmingCharacters(in: .whitespaces)
                guard !suffix.isEmpty && !ocrChar.isEmpty else { continue }
                indicators.append(VisionIndicator(suffix: " \(suffix)", ocrChar: ocrChar))
            }
        }

        DebugLog.log("components", "Loaded \(indicators.count) vision indicators")
        return indicators
    }

    /// Parsed text cleanup rules: prefix characters to strip, the separators
    /// OCR reads between items it merged into one line, and labels to exclude.
    struct TextCleanupRules: Sendable {
        let stripPrefixes: [Character]
        let segmentSeparators: [Character]
        let excludeLabels: Set<String>
    }

    /// File name of the text cleanup rules in the component search paths.
    static let textCleanupFileName = "text-cleanup.md"

    /// Every path `text-cleanup.md` is looked up at, in resolution order.
    static func textCleanupCandidates() -> [String] {
        searchPaths().map { $0.appendingPathComponent(textCleanupFileName).path }
    }

    /// Load text cleanup rules from `text-cleanup.md` in component search paths.
    /// Returns default empty rules if no file is found.
    static func loadTextCleanupRules() -> TextCleanupRules {
        for candidate in textCleanupCandidates() {
            guard let content = try? String(contentsOfFile: candidate, encoding: .utf8) else {
                continue
            }
            return parseTextCleanup(content: content)
        }
        return TextCleanupRules(stripPrefixes: [], segmentSeparators: [], excludeLabels: [])
    }

    /// Parse the `## Strip Prefixes`, `## Segment Separators` and
    /// `## Exclude Labels` sections.
    static func parseTextCleanup(content: String) -> TextCleanupRules {
        var prefixes: [Character] = []
        var separators: [Character] = []
        var excludes: Set<String> = []
        var currentSection: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## Strip Prefixes") {
                currentSection = "prefixes"
                continue
            }
            if trimmed.hasPrefix("## Segment Separators") {
                currentSection = "separators"
                continue
            }
            if trimmed.hasPrefix("## Exclude Labels") {
                currentSection = "excludes"
                continue
            }
            if trimmed.hasPrefix("##") {
                currentSection = nil
                continue
            }
            guard trimmed.hasPrefix("- ") else { continue }
            let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch currentSection {
            case "prefixes":
                if let char = value.first { prefixes.append(char) }
            case "separators":
                if let char = value.first { separators.append(char) }
            case "excludes":
                excludes.insert(value)
            default:
                break
            }
        }

        DebugLog.log("components",
            "Loaded text cleanup: \(prefixes.count) prefixes, \(separators.count) separators, " +
            "\(excludes.count) excludes")
        return TextCleanupRules(
            stripPrefixes: prefixes, segmentSeparators: separators, excludeLabels: excludes)
    }

    /// Find all `.md` files in a directory (non-recursive).
    private static func findComponentFiles(in dirURL: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dirURL.path) else { return [] }

        guard let contents = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
