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
        let skipPermissions = PermissionPolicy.parseSkipPermissions(from: args)
        DebugLog.enabled = args.contains("--debug")
        DebugLog.reset()
        let config = PermissionPolicy.loadConfig()
        let policy = PermissionPolicy(skipPermissions: skipPermissions, config: config)

        // Log startup info to stderr (always) and debug log file (when --debug)
        if skipPermissions {
            DebugLog.log("startup", "Permission mode: all tools enabled (--dangerously-skip-permissions)")
        } else if let cfg = config {
            DebugLog.log("startup", "Permission mode: config-based (\(PermissionPolicy.configPath))")
            DebugLog.log("startup", "  allow: \(cfg.allow ?? [])")
            DebugLog.log("startup", "  deny: \(cfg.deny ?? [])")
            DebugLog.log("startup", "  blockedApps: \(cfg.blockedApps ?? [])")
        } else {
            DebugLog.log("startup", "Permission mode: fail-closed (readonly tools only)")
        }

        if DebugLog.enabled {
            // Truncate the debug log on each server start (startup lines already written above)
        } else {
            // Log startup to stderr even without --debug (lightweight, useful for MCP client logs)
            if skipPermissions {
                fputs("[startup] Permission mode: all tools enabled (--dangerously-skip-permissions)\n", stderr)
            } else if let cfg = config {
                fputs("[startup] Permission mode: config-based (\(PermissionPolicy.configPath))\n", stderr)
                fputs("[startup]   allow: \(cfg.allow ?? [])\n", stderr)
                fputs("[startup]   deny: \(cfg.deny ?? [])\n", stderr)
                fputs("[startup]   blockedApps: \(cfg.blockedApps ?? [])\n", stderr)
            } else {
                fputs("[startup] Permission mode: fail-closed (readonly tools only)\n", stderr)
            }
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

// MARK: - JSONValue convenience extensions

extension JSONValue {
    func asString() -> String? {
        if case .string(let s) = self { return s }
        return nil
    }

    func asNumber() -> Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    func asInt() -> Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    func asStringArray() -> [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap { $0.asString() }
    }
}
