// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Entry point for the iPhone Mirroring MCP server.
// ABOUTME: Initializes subsystems and starts the JSON-RPC server loop over stdio.

import Darwin
import Foundation
import HelperLib

/// iPhone Mirroring capabilities for building the default target context.
private let iphoneMirroringCapabilities: Set<TargetCapability> = [
    .menuActions, .spotlight, .home, .appSwitcher,
]

@main
struct IPhoneMirroirMCP {
    static func main() {
        // Ignore SIGPIPE so the server doesn't crash when the MCP client
        // disconnects or its stdio pipe closes unexpectedly.
        signal(SIGPIPE, SIG_IGN)

        // Parse CLI flags
        let args = CommandLine.arguments

        // Handle subcommands before MCP server initialization
        if args.count >= 2 && args[1] == "test" {
            let exitCode = TestRunner.run(arguments: Array(args.dropFirst(2)))
            Darwin.exit(exitCode)
        }
        if args.count >= 2 && args[1] == "record" {
            let exitCode = RecordCommand.run(arguments: Array(args.dropFirst(2)))
            Darwin.exit(exitCode)
        }
        if args.count >= 2 && args[1] == "compile" {
            let exitCode = CompileCommand.run(arguments: Array(args.dropFirst(2)))
            Darwin.exit(exitCode)
        }
        if args.count >= 2 && args[1] == "doctor" {
            let exitCode = DoctorCommand.run(arguments: Array(args.dropFirst(2)))
            Darwin.exit(exitCode)
        }
        let skipPermissions = PermissionPolicy.parseSkipPermissions(from: args)
        DebugLog.enabled = args.contains("--debug")
        DebugLog.reset()
        if DebugLog.enabled {
            DebugLog.persist("startup", "Debug logging enabled (--debug)")
        }
        let config = PermissionPolicy.loadConfig()
        let policy = PermissionPolicy(skipPermissions: skipPermissions, config: config)

        // Log startup info to stderr and the log file (always persisted)
        if skipPermissions {
            DebugLog.persist("startup", "Permission mode: all tools enabled (--dangerously-skip-permissions)")
        } else if let cfg = config {
            DebugLog.persist("startup", "Permission mode: config-based (\(PermissionPolicy.configPath))")
            DebugLog.persist("startup", "  allow: \(cfg.allow ?? [])")
            DebugLog.persist("startup", "  deny: \(cfg.deny ?? [])")
            DebugLog.persist("startup", "  blockedApps: \(cfg.blockedApps ?? [])")
        } else {
            DebugLog.persist("startup", "Permission mode: fail-closed (readonly tools only)")
        }

        // Log denied and hidden tools so silent exclusions are visible
        let deniedTools = PermissionPolicy.mutatingTools.filter { tool in
            if case .denied = policy.checkTool(tool) { return true }
            return false
        }.sorted()
        let hiddenTools = PermissionPolicy.mutatingTools.filter { tool in
            !policy.isToolVisible(tool)
        }.sorted()

        if !deniedTools.isEmpty {
            DebugLog.persist("startup", "WARNING: denied tools: \(deniedTools)")
        }
        if !hiddenTools.isEmpty {
            DebugLog.persist("startup", "WARNING: hidden from tools/list: \(hiddenTools)")
        }

        let registry = buildTargetRegistry()
        let server = MCPServer(policy: policy)

        // Log active targets
        let targetNames = registry.allTargetNames
        DebugLog.persist("startup", "Targets: \(targetNames) (active: \(registry.activeTargetName))")

        registerTools(server: server, registry: registry, policy: policy)

        // Start the MCP server loop
        server.run()
    }

    /// Build a TargetRegistry from targets.json or fall back to a single iPhone target.
    static func buildTargetRegistry() -> TargetRegistry {
        if let file = TargetConfigLoader.load(), !file.targets.isEmpty {
            return buildMultiTargetRegistry(configs: file.targets,
                                            defaultName: file.defaultTarget)
        }

        // Single-target mode: identical behavior to pre-multi-target code
        let bridge = MirroringBridge()
        let capture = ScreenCapture(bridge: bridge)
        let ctx = TargetContext(
            name: "iphone",
            bridge: bridge,
            input: InputSimulation(bridge: bridge),
            capture: capture,
            describer: ScreenDescriber(bridge: bridge, capture: capture),
            recorder: ScreenRecorder(bridge: bridge),
            capabilities: iphoneMirroringCapabilities
        )
        return TargetRegistry(targets: ["iphone": ctx], defaultName: "iphone")
    }

    /// Build a TargetRegistry from multiple target configurations.
    private static func buildMultiTargetRegistry(
        configs: [String: TargetConfig],
        defaultName: String?
    ) -> TargetRegistry {
        var targets = [String: TargetContext]()

        for (name, config) in configs {
            let bridge: any WindowBridging
            let capabilities: Set<TargetCapability>

            if config.type == "iphone-mirroring" {
                bridge = MirroringBridge(
                    targetName: name,
                    bundleID: config.bundleID
                )
                capabilities = iphoneMirroringCapabilities
            } else {
                bridge = GenericWindowBridge(
                    targetName: name,
                    bundleID: config.bundleID ?? "",
                    processName: config.processName,
                    windowTitleContains: config.windowTitleContains
                )
                capabilities = []
            }

            let cursorMode: CursorMode = config.type == "iphone-mirroring"
                ? .direct : .preserving
            let capture = ScreenCapture(bridge: bridge)
            targets[name] = TargetContext(
                name: name,
                bridge: bridge,
                input: InputSimulation(bridge: bridge, cursorMode: cursorMode),
                capture: capture,
                describer: ScreenDescriber(bridge: bridge, capture: capture),
                recorder: ScreenRecorder(bridge: bridge),
                capabilities: capabilities
            )
        }

        // Resolve default: use specified default if it exists, otherwise first alphabetical.
        let sortedNames = targets.keys.sorted()
        let resolvedDefault: String
        if let specified = defaultName, targets[specified] != nil {
            resolvedDefault = specified
        } else {
            if let specified = defaultName {
                DebugLog.log("TargetRegistry",
                    "Configured default '\(specified)' not found in targets \(sortedNames), "
                    + "falling back to '\(sortedNames.first ?? "")'")
            }
            resolvedDefault = sortedNames.first!  // Safe: configs was checked !isEmpty above
        }
        return TargetRegistry(targets: targets, defaultName: resolvedDefault)
    }
}

