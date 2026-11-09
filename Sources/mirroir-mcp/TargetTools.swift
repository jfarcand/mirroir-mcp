// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the list_targets and switch_target MCP tools.
// ABOUTME: Allows LLMs to discover configured targets and switch the active target.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerTargetTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        // list_targets — show all configured targets with status
        server.registerTool(MCPToolDefinition(
            name: "list_targets",
            description: """
                Lists all configured targets with status, window size, and which is active. \
                Targets are window automation endpoints (iPhone Mirroring, macOS app windows). \
                Each line names the tools that do not exist on that target: calling one \
                returns "unsupported" and sends nothing.
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
                    let unsupported = ctx.profile.unsupportedOperations.map(\.rawValue)
                    let tools = unsupported.isEmpty
                        ? "every tool"
                        : "unsupported here: \(unsupported.joined(separator: ", "))"
                    lines.append("- \(ctx.name)\(isActive): \(state) (\(sizeDesc)) "
                        + "[\(ctx.profile.displayName); \(tools)]")
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
