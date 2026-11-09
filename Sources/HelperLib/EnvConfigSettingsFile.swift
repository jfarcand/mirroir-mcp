// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Finds and reads the settings.json files EnvConfig takes its values from.
// ABOUTME: One environment variable names a single file to load instead, so a test run can leave the developer's settings out.

import Foundation

extension EnvConfig {

    /// Environment variable naming the only settings.json to load. When it is
    /// set and not empty, the project-local and global files are not read; a
    /// path where no file exists loads no settings at all.
    public static let settingsFileVariable = "MIRROIR_SETTINGS_FILE"

    /// The settings file name inside a config directory.
    static let settingsFileName = "settings.json"

    /// The settings this process runs with: the file `settingsFileVariable`
    /// names, or else the global file under the project-local one, key by key.
    static func loadSettings(
        environment: [String: String], localConfigDir: String, globalConfigDir: String
    ) -> [String: Any] {
        if let only = environment[settingsFileVariable], !only.isEmpty {
            return readSettingsFile(atPath: only)
        }
        return mergedSettings(
            localPath: (localConfigDir as NSString).appendingPathComponent(settingsFileName),
            globalPath: (globalConfigDir as NSString).appendingPathComponent(settingsFileName))
    }

    /// Merge the global file under the project-local file, key by key: a key
    /// in the project-local file overrides the same key in the global file,
    /// and every global key the project file does not set still applies.
    /// A missing file contributes nothing.
    static func mergedSettings(localPath: String, globalPath: String) -> [String: Any] {
        let global = readSettingsFile(atPath: globalPath)
        let local = readSettingsFile(atPath: localPath)
        return global.merging(local) { _, projectValue in projectValue }
    }

    /// Read one settings.json file; a missing or malformed file yields an
    /// empty dictionary (malformed files warn on stderr).
    static func readSettingsFile(atPath path: String) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fputs("Warning: settings.json at \(path) is not a JSON object\n", stderr)
                return [:]
            }
            return json
        } catch {
            fputs("Warning: Failed to parse settings.json at \(path): \(error.localizedDescription)\n", stderr)
            return [:]
        }
    }
}
