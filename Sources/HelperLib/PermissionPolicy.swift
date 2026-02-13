// ABOUTME: Fail-closed permission engine for MCP tool access control.
// ABOUTME: Gates mutating tools behind explicit opt-in via CLI flags or JSON config file.

import Foundation

/// Result of a permission check for a tool or app launch.
public enum PermissionDecision: Sendable, Equatable {
    case allowed
    case denied(reason: String)
}

/// JSON-decodable permission configuration loaded from ~/.iphone-mirroir-mcp/permissions.json.
/// The loader checks project-local (<cwd>/.iphone-mirroir-mcp/) first, then global (~/.iphone-mirroir-mcp/).
public struct PermissionConfig: Codable, Sendable {
    /// Whitelist of mutating tools to allow (case-insensitive).
    public var allow: [String]?
    /// Blocklist of tools to deny, overrides allow (case-insensitive).
    public var deny: [String]?
    /// App names that launch_app should refuse to open (case-insensitive).
    public var blockedApps: [String]?

    public init(allow: [String]? = nil, deny: [String]? = nil, blockedApps: [String]? = nil) {
        self.allow = allow
        self.deny = deny
        self.blockedApps = blockedApps
    }
}

/// Controls which MCP tools are visible and callable based on CLI flags and config.
public struct PermissionPolicy: Sendable {
    /// When true, all tools are allowed regardless of config.
    public let skipPermissions: Bool
    /// Optional config loaded from disk.
    public let config: PermissionConfig?

    /// Base directory name for config files (both global and project-local).
    public static let configDirName = ".iphone-mirroir-mcp"

    /// Path to the global config directory.
    public static var globalConfigDir: String {
        ("~/" + configDirName as NSString).expandingTildeInPath
    }

    /// Path to the project-local config directory (relative to current working directory).
    public static var localConfigDir: String {
        FileManager.default.currentDirectoryPath + "/" + configDirName
    }

    /// Display path for error messages (shows the global config path with tilde).
    public static let configPath = "~/.iphone-mirroir-mcp/permissions.json"

    /// Tools that are always visible and allowed (observation-only, no side effects).
    public static let readonlyTools: Set<String> = [
        "screenshot",
        "describe_screen",
        "start_recording",
        "stop_recording",
        "get_orientation",
        "status",
        "list_scenarios",
        "get_scenario",
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
        "shake",
        "launch_app",
        "open_url",
        "press_home",
        "press_app_switcher",
        "spotlight",
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

    /// Returns the scenario directories in resolution order (project-local first, then global).
    public static var scenarioDirs: [String] {
        [localConfigDir + "/scenarios", globalConfigDir + "/scenarios"]
    }

    /// Parse CLI arguments for the skip-permissions flag.
    /// Returns true if `--dangerously-skip-permissions` or `--yolo` is present.
    public static func parseSkipPermissions(from args: [String]) -> Bool {
        args.contains("--dangerously-skip-permissions") || args.contains("--yolo")
    }
}
