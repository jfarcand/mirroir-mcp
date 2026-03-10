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

    /// Search paths for COMPONENT.md files, in resolution order.
    ///
    /// 1. `<cwd>/.mirroir-mcp/components/` (project-local)
    /// 2. `~/.mirroir-mcp/components/` (global)
    /// 3. `<cwd>/.mirroir-mcp/skills/components/ios/` (skills repo cloned into config dir)
    /// 4. `<cwd>/.mirroir-mcp/skills/components/custom/` (skills repo cloned into config dir)
    /// 5. `../mirroir-skills/components/ios/` (sibling skills repo, iOS)
    /// 6. `../mirroir-skills/components/custom/` (sibling skills repo, custom)
    static func searchPaths() -> [URL] {
        let cwd = FileManager.default.currentDirectoryPath
        let home = ("~" as NSString).expandingTildeInPath
        let configDir = PermissionPolicy.configDirName

        return [
            URL(fileURLWithPath: cwd + "/" + configDir + "/components"),
            URL(fileURLWithPath: home + "/" + configDir + "/components"),
            URL(fileURLWithPath: cwd + "/" + configDir + "/skills/components/ios"),
            URL(fileURLWithPath: cwd + "/" + configDir + "/skills/components/custom"),
            URL(fileURLWithPath: cwd + "/../mirroir-skills/components/ios"),
            URL(fileURLWithPath: cwd + "/../mirroir-skills/components/custom"),
        ]
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
                guard !seen.contains(stem) else { continue }

                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    continue
                }

                let definition = ComponentSkillParser.parse(content: content, fallbackName: stem)
                seen.insert(definition.name)
                definitions.append(definition)
            }
        }

        DebugLog.log("components", "Loaded \(definitions.count) definitions (cwd=\(cwd))")
        return definitions
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
