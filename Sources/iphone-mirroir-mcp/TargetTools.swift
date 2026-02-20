// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the list_targets and switch_target MCP tools.
// ABOUTME: Allows LLMs to discover configured targets and switch the active target.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
    static func registerTargetTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        // list_targets — show all configured targets with status
        server.registerTool(MCPToolDefinition(
            name: "list_targets",
            description: """
                Lists all configured targets with status, window size, and which is active. \
                Targets are window automation endpoints (iPhone Mirroring, Android emulators, etc.).
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { _ in
                let active = registry.activeTargetName
                var lines: [String] = []

                for ctx in registry.allTargets {
                    let isActive = ctx.name == active ? " (active)" : ""
                    let state = ctx.bridge.getState()
                    let sizeDesc: String
                    if let info = ctx.bridge.getWindowInfo() {
                        sizeDesc = "\(Int(info.size.width))x\(Int(info.size.height))"
                    } else {
                        sizeDesc = "no window"
                    }
                    let caps = ctx.capabilities.isEmpty
                        ? "generic"
                        : ctx.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
                    lines.append("- \(ctx.name)\(isActive): \(state) (\(sizeDesc)) [\(caps)]")
                }

                return .text(lines.joined(separator: "\n"))
            }
        ))

        // switch_target — change the active target
        server.registerTool(MCPToolDefinition(
            name: "switch_target",
            description: """
                Changes the active target for subsequent calls. \
                Use list_targets to see available targets.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Name of the target to switch to"),
                    ])
                ]),
                "required": .array([.string("target")]),
            ],
            handler: { args in
                guard let name = args["target"]?.asString() else {
                    return .error("Missing required parameter: target (string)")
                }

                if registry.switchActive(to: name) {
                    return .text("Switched active target to '\(name)'")
                }

                let available = registry.allTargetNames.joined(separator: ", ")
                return .error("Unknown target '\(name)'. Available: \(available)")
            }
        ))
    }
}
