// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Entry point for the iPhone Mirroring MCP server.
// ABOUTME: Initializes subsystems and starts the JSON-RPC server loop over stdio.

import Darwin
import Foundation
import HelperLib

@main
struct IPhoneMirroirMCP {
    static func main() {
        // Ignore SIGPIPE so the server doesn't crash when the MCP client
        // disconnects or its stdio pipe closes unexpectedly.
        signal(SIGPIPE, SIG_IGN)

        // Parse CLI flags
        let args = CommandLine.arguments

        // Handle `test` subcommand before MCP server initialization
        if args.count >= 2 && args[1] == "test" {
            let exitCode = TestRunner.run(arguments: Array(args.dropFirst(2)))
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

        let bridge = MirroringBridge()
        let capture = ScreenCapture(bridge: bridge)
        let recorder = ScreenRecorder(bridge: bridge)
        let input = InputSimulation(bridge: bridge)
        let describer = ScreenDescriber(bridge: bridge)
        let server = MCPServer(policy: policy)

        registerTools(server: server, bridge: bridge, capture: capture,
                      recorder: recorder, input: input, describer: describer,
                      policy: policy)

        // Start the MCP server loop
        server.run()
    }
}

