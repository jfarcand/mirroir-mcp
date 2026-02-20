// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Target configuration types for multi-window automation targets.
// ABOUTME: Loads targets.json from project-local or global config directory.

import Foundation
import HelperLib

/// Configuration for a single automation target read from targets.json.
struct TargetConfig: Codable, Sendable {
    /// Target type: "iphone-mirroring" or "generic-window".
    let type: String
    /// macOS bundle identifier for the target app.
    let bundleID: String?
    /// macOS process name for the target app.
    let processName: String?
    /// Substring match against window title to disambiguate multiple windows.
    let windowTitleContains: String?

    enum CodingKeys: String, CodingKey {
        case type
        case bundleID = "bundle_id"
        case processName = "process_name"
        case windowTitleContains = "window_title_contains"
    }
}

/// Top-level structure of targets.json.
struct TargetsFile: Codable, Sendable {
    let targets: [String: TargetConfig]
    let defaultTarget: String?

    enum CodingKeys: String, CodingKey {
        case targets
        case defaultTarget = "default_target"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.targets = try container.decodeIfPresent([String: TargetConfig].self,
                                                      forKey: .targets) ?? [:]
        self.defaultTarget = try container.decodeIfPresent(String.self,
                                                            forKey: .defaultTarget)
    }
}

/// Loads target configuration from disk following the same resolution pattern
/// as PermissionPolicy: project-local first, then global.
enum TargetConfigLoader {

    /// Load targets.json, returning nil if no file exists.
    static func load() -> TargetsFile? {
        let localPath = PermissionPolicy.localConfigDir + "/targets.json"
        let globalPath = PermissionPolicy.globalConfigDir + "/targets.json"

        let path: String
        if FileManager.default.fileExists(atPath: localPath) {
            path = localPath
        } else if FileManager.default.fileExists(atPath: globalPath) {
            path = globalPath
        } else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            let file = try decoder.decode(TargetsFile.self, from: data)
            DebugLog.log("TargetConfig", "Loaded targets from \(path)")
            return file
        } catch {
            fputs("Warning: Failed to parse targets config at \(path): \(error.localizedDescription)\n", stderr)
            return nil
        }
    }
}
