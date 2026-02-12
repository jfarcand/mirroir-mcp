// Copyright 2026 jfarcand
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
        let debugMode = args.contains("--debug")
        let config = PermissionPolicy.loadConfig()
        let policy = PermissionPolicy(skipPermissions: skipPermissions, config: config)

        // Log startup info to stderr (always) and debug log file (when --debug)
        var startupLines: [String] = []
        if debugMode {
            startupLines.append("[startup] Debug mode enabled (--debug)")
        }
        if skipPermissions {
            startupLines.append("[startup] Permission mode: all tools enabled (--dangerously-skip-permissions)")
        } else if let cfg = config {
            startupLines.append("[startup] Permission mode: config-based (\(PermissionPolicy.configPath))")
            startupLines.append("[startup]   allow: \(cfg.allow ?? [])")
            startupLines.append("[startup]   deny: \(cfg.deny ?? [])")
            startupLines.append("[startup]   blockedApps: \(cfg.blockedApps ?? [])")
        } else {
            startupLines.append("[startup] Permission mode: fail-closed (readonly tools only)")
        }

        let logContent = startupLines.map { $0 + "\n" }.joined()
        fputs(logContent, stderr)
        if debugMode {
            let debugLogPath = "/tmp/iphone-mirroir-mcp-debug.log"
            // Truncate and rewrite the debug log on each server start
            FileManager.default.createFile(atPath: debugLogPath, contents: Data(logContent.utf8))
        }

        // Redirect stderr for logging (stdout is reserved for MCP JSON-RPC)
        let bridge = MirroringBridge()
        let capture = ScreenCapture(bridge: bridge)
        let recorder = ScreenRecorder(bridge: bridge)
        let input = InputSimulation(bridge: bridge, debug: debugMode)
        let describer = ScreenDescriber(bridge: bridge)
        let server = MCPServer(policy: policy, debug: debugMode)

        registerTools(server: server, bridge: bridge, capture: capture,
                      recorder: recorder, input: input, describer: describer,
                      policy: policy, debug: debugMode)

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
