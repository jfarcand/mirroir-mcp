// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Fail-closed permission engine for MCP tool access control.
// ABOUTME: Gates mutating tools behind explicit opt-in via CLI flags or JSON config file.

import Foundation

/// Result of a permission check for a tool or app launch.
public enum PermissionDecision: Sendable, Equatable {
    case allowed
    case denied(reason: String)
}

/// Per-app tool rules layered on top of the global `allow` / `deny` lists.
/// Evaluated by `PermissionPolicy.checkTool(_:forApp:)` during exploration of
/// a specific app. Both fields are case-insensitive.
public struct AppToolRules: Codable, Sendable {
    /// Tools explicitly allowed for this app, even if the global rules would deny them.
    public var allow: [String]?
    /// Tools denied for this app, overriding the global allow list. Useful for
    /// locking down typing or URL opening while exploring a sensitive app.
    public var deny: [String]?

    public init(allow: [String]? = nil, deny: [String]? = nil) {
        self.allow = allow
        self.deny = deny
    }
}

/// JSON-decodable permission configuration loaded from ~/.mirroir-mcp/permissions.json.
/// The loader checks project-local (<cwd>/.mirroir-mcp/) first, then global (~/.mirroir-mcp/).
public struct PermissionConfig: Codable, Sendable {
    /// Whitelist of mutating tools to allow (case-insensitive).
    public var allow: [String]?
    /// Blocklist of tools to deny, overrides allow (case-insensitive).
    public var deny: [String]?
    /// App names that launch_app should refuse to open (case-insensitive).
    public var blockedApps: [String]?
    /// Element text patterns the explorer should never tap (case-insensitive containment).
    public var skipElements: [String]?
    /// Extra text patterns that make a skill step require confirmation before a
    /// run may execute it. Layered on top of
    /// `DestructiveStepDetector.builtInConfirmPatterns`, never replacing them —
    /// the built-ins are safety-critical. A pattern wrapped in slashes is a
    /// regular expression.
    public var confirmElements: [String]?
    /// Per-app tool rules. Keys are app display names (case-insensitive).
    /// When an app is being explored, its entry — if any — layers on top of the
    /// global `allow`/`deny` lists: per-app `deny` wins over global `allow`, and
    /// per-app `allow` opens tools that the global lists would close.
    public var perApp: [String: AppToolRules]?

    public init(
        allow: [String]? = nil, deny: [String]? = nil,
        blockedApps: [String]? = nil, skipElements: [String]? = nil,
        confirmElements: [String]? = nil,
        perApp: [String: AppToolRules]? = nil
    ) {
        self.allow = allow
        self.deny = deny
        self.blockedApps = blockedApps
        self.skipElements = skipElements
        self.confirmElements = confirmElements
        self.perApp = perApp
    }
}

/// Controls which MCP tools are visible and callable based on CLI flags and config.
public struct PermissionPolicy: Sendable {
    /// When true, all tools are allowed regardless of config.
    public let skipPermissions: Bool
    /// Optional config loaded from disk.
    public let config: PermissionConfig?

    /// Base directory name for config files (both global and project-local).
    public static let configDirName = ".mirroir-mcp"

    /// Path to the global config directory.
    public static var globalConfigDir: String {
        ("~/" + configDirName as NSString).expandingTildeInPath
    }

    /// Path to the project-local config directory (relative to current working directory).
    public static var localConfigDir: String {
        FileManager.default.currentDirectoryPath + "/" + configDirName
    }

    /// Display path for error messages (shows the global config path with tilde).
    public static let configPath = "~/.mirroir-mcp/permissions.json"

    /// Tools that are always visible and allowed (observation-only, no side effects).
    public static let readonlyTools: Set<String> = [
        "screenshot",
        "describe_screen",
        "start_recording",
        "stop_recording",
        "get_orientation",
        "status",
        "check_health",
        "list_targets",
        "list_skills",
        "get_skill",
        "calibrate_component",
        "classify_screen",
    ]

    /// Tools that mutate iPhone state and require explicit permission.
    public static let mutatingTools: Set<String> = [
        "tap",
        "swipe",
        "drag",
        "type_text",
        "press_key",
        "long_press",
        "double_tap",
        "touch",
        "pinch",
        "rotate",
        "hold_keys",
        "multi_touch",
        "shake",
        "launch_app",
        "open_url",
        "press_home",
        "press_app_switcher",
        "press_back",
        "spotlight",
        "scroll_to",
        "reset_app",
        "measure",
        "set_network",
        "switch_target",
        "record_step",
        "save_compiled",
        "generate_skill",
    ]

    public init(skipPermissions: Bool, config: PermissionConfig?) {
        self.skipPermissions = skipPermissions
        self.config = config
    }

    /// Check whether a tool is allowed to execute.
    ///
    /// Logic:
    /// 1. Readonly tools are always allowed.
    /// 2. If skipPermissions is true, all tools are allowed.
    /// 3. If the tool is in the deny list, it is denied (deny overrides allow).
    /// 4. If the tool is in the allow list, it is allowed.
    /// 5. If an allow list exists but the tool is not in it, it is denied.
    /// 6. If no config or no allow list, mutating tools are denied (fail-closed).
    public func checkTool(_ toolName: String) -> PermissionDecision {
        let name = toolName.lowercased()

        if Self.readonlyTools.contains(where: { $0.lowercased() == name }) {
            return .allowed
        }

        if skipPermissions {
            return .allowed
        }

        if let denyList = config?.deny,
           denyList.contains(where: { $0.lowercased() == name }) {
            return .denied(reason:
                "Tool '\(toolName)' is blocked by deny list in permissions config. " +
                "Remove it from the deny list in \(Self.configPath) to allow it.")
        }

        if let allowList = config?.allow {
            if allowList.contains("*") {
                return .allowed
            }
            if allowList.contains(where: { $0.lowercased() == name }) {
                return .allowed
            }
            return .denied(reason:
                "Tool '\(toolName)' is not in the allow list. " +
                "Add it to the allow list in \(Self.configPath) or use --dangerously-skip-permissions.")
        }

        return .denied(reason:
            "Tool '\(toolName)' requires explicit permission. " +
            "Use --dangerously-skip-permissions or configure \(Self.configPath).")
    }

    /// Check a tool against global rules AND the per-app overrides (if any).
    /// Precedence, after the global `checkTool` decision is computed:
    ///   1. Per-app `deny` always wins (denies even a globally-allowed tool).
    ///   2. Per-app `allow` can open a tool that was globally denied.
    /// Readonly tools and `--dangerously-skip-permissions` behave exactly as in
    /// `checkTool` — per-app rules only affect mutating tools.
    public func checkTool(_ toolName: String, forApp appName: String) -> PermissionDecision {
        let baseline = checkTool(toolName)
        guard let rules = config?.perApp?[caseInsensitive: appName] else { return baseline }
        let name = toolName.lowercased()

        if let denyList = rules.deny,
           denyList.contains(where: { $0.lowercased() == name }) {
            return .denied(reason:
                "Tool '\(toolName)' is denied for app '\(appName)' by permissions.json perApp rules. "
                + "Remove it from perApp.\(appName).deny to allow it during this app's exploration.")
        }

        if case .denied = baseline,
           let allowList = rules.allow,
           allowList.contains(where: { $0.lowercased() == name }) {
            return .allowed
        }

        return baseline
    }

    /// Return the subset of `tools` that are denied for `appName` when per-app
    /// rules are taken into account. Used at exploration start to fail fast when
    /// the app's rules block something the explorer actually needs (e.g. `tap`).
    public func toolsDenied(
        for appName: String, requiredTools tools: [String]
    ) -> [String] {
        tools.filter {
            if case .denied = checkTool($0, forApp: appName) { return true }
            return false
        }
    }

    /// Check whether an app is allowed to be launched.
    public func checkAppLaunch(_ appName: String) -> PermissionDecision {
        let name = appName.lowercased()

        if let blockedApps = config?.blockedApps,
           blockedApps.contains(where: { $0.lowercased() == name }) {
            return .denied(reason:
                "App '\(appName)' is blocked by permissions config. " +
                "Remove it from blockedApps in \(Self.configPath) to allow launching it.")
        }

        return .allowed
    }

    /// Whether a tool should appear in tools/list output.
    /// Readonly tools are always visible. Mutating tools are only visible if they would be allowed.
    public func isToolVisible(_ toolName: String) -> Bool {
        let name = toolName.lowercased()

        if Self.readonlyTools.contains(where: { $0.lowercased() == name }) {
            return true
        }

        if case .allowed = checkTool(toolName) {
            return true
        }

        return false
    }

    /// Load permission config, checking project-local directory first then global.
    /// Returns nil if no file exists or is malformed (fail-closed defaults).
    public static func loadConfig() -> PermissionConfig? {
        let localPath = localConfigDir + "/permissions.json"
        let globalPath = globalConfigDir + "/permissions.json"

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
            return try decoder.decode(PermissionConfig.self, from: data)
        } catch {
            fputs("Warning: Failed to parse permissions config at \(path): \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    /// Returns the skill directories in resolution order (project-local first, then global).
    public static var skillDirs: [String] {
        [localConfigDir + "/skills", globalConfigDir + "/skills"]
    }

    /// Returns the agent profile directories in resolution order (project-local first, then global).
    public static var agentDirs: [String] {
        [localConfigDir + "/agents", globalConfigDir + "/agents"]
    }

    /// Returns the prompt directories in resolution order (project-local first, then global).
    public static var promptDirs: [String] {
        [localConfigDir + "/prompts", globalConfigDir + "/prompts"]
    }

    /// Parse CLI arguments for the skip-permissions flag.
    /// Returns true if `--dangerously-skip-permissions` or `--yolo` is present.
    public static func parseSkipPermissions(from args: [String]) -> Bool {
        args.contains("--dangerously-skip-permissions") || args.contains("--yolo")
    }
}

private extension Dictionary where Key == String {
    /// Case-insensitive subscript lookup. Used so `perApp["Banking"]` matches
    /// `perApp["banking"]` in the JSON config.
    subscript(caseInsensitive key: String) -> Value? {
        let lower = key.lowercased()
        return first(where: { $0.key.lowercased() == lower })?.value
    }
}
