// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers info-related MCP tools: get_orientation, status.
// ABOUTME: Each tool maps MCP JSON-RPC calls to the bridge for querying mirroring state.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
    static func registerInfoTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        // get_orientation — report device orientation
        server.registerTool(MCPToolDefinition(
            name: "get_orientation",
            description: """
                Get the current device orientation of the mirrored iPhone. \
                Returns "portrait" or "landscape" based on the mirroring \
                window dimensions. Useful for adapting touch coordinates \
                and understanding the current screen layout.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { args in
                let ctx = registry.resolve(args["target"]?.asString())
                guard let ctx else { return .error("Unknown target '\(args["target"]?.asString() ?? "")'") }
                let bridge = ctx.bridge

                guard let orientation = bridge.getOrientation() else {
                    return .error(
                        "Cannot determine orientation. Is iPhone Mirroring running?")
                }

                let info = bridge.getWindowInfo()
                let sizeDesc = info.map {
                    "\(Int($0.size.width))x\(Int($0.size.height))"
                } ?? "unknown"

                return .text(
                    "Orientation: \(orientation.rawValue) (window: \(sizeDesc))")
            }
        ))

        // check_health — single diagnostic tool for setup debugging
        server.registerTool(MCPToolDefinition(
            name: "check_health",
            description: """
                Run a comprehensive health check of the iPhone Mirroring setup. \
                Checks mirroring window state, helper daemon connectivity, \
                Karabiner virtual HID readiness, and screen capture availability. \
                Use this to diagnose setup issues in a single call.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { args in
                let ctx = registry.resolve(args["target"]?.asString())
                guard let ctx else { return .error("Unknown target '\(args["target"]?.asString() ?? "")'") }
                let bridge = ctx.bridge
                let input = ctx.input
                let capture = ctx.capture

                var checks: [String] = []
                var allOk = true

                // 1. iPhone Mirroring process
                let process = bridge.findProcess()
                if process != nil {
                    checks.append("[ok] iPhone Mirroring app is running")
                } else {
                    checks.append("[FAIL] iPhone Mirroring app is not running")
                    allOk = false
                }

                // 2. Mirroring window state
                let state = bridge.getState()
                switch state {
                case .connected:
                    let info = bridge.getWindowInfo()
                    let size = info.map {
                        "\(Int($0.size.width))x\(Int($0.size.height))"
                    } ?? "unknown"
                    checks.append("[ok] Mirroring connected (window: \(size))")
                case .paused:
                    checks.append("[WARN] Mirroring is paused — click the window to resume")
                    allOk = false
                case .noWindow:
                    checks.append("[FAIL] App running but no mirroring window found")
                    allOk = false
                case .notRunning:
                    checks.append("[FAIL] No mirroring window — open iPhone Mirroring")
                    allOk = false
                }

                // 3. Helper daemon
                if let status = input.helperStatus() {
                    let kb = status["keyboard_ready"] as? Bool ?? false
                    let pt = status["pointing_ready"] as? Bool ?? false
                    if kb && pt {
                        checks.append("[ok] Helper daemon connected (keyboard + pointing ready)")
                    } else {
                        checks.append(
                            "[WARN] Helper connected but devices not ready " +
                            "(keyboard=\(kb), pointing=\(pt))")
                        allOk = false
                    }
                } else {
                    checks.append(
                        "[FAIL] Helper daemon not reachable — " +
                        "run 'npx iphone-mirroir-mcp setup' or check launchd")
                    allOk = false
                }

                // 4. Screen capture
                let screenshot = capture.captureBase64()
                if screenshot != nil {
                    checks.append("[ok] Screen capture working")
                } else {
                    checks.append(
                        "[FAIL] Screen capture failed — " +
                        "grant Screen Recording permission in System Settings")
                    allOk = false
                }

                let summary = allOk ? "All checks passed" : "Issues detected"
                let output = "\(summary)\n\n" + checks.joined(separator: "\n")
                return .text(output)
            }
        ))

        // status — get the current mirroring connection state
        server.registerTool(MCPToolDefinition(
            name: "status",
            description: """
                Get the current status of the iPhone Mirroring connection and Karabiner helper. \
                Returns whether the app is running, connected, paused, or has no window. \
                Also reports whether the Karabiner helper daemon is available for input.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { args in
                let ctx = registry.resolve(args["target"]?.asString())
                guard let ctx else { return .error("Unknown target '\(args["target"]?.asString() ?? "")'") }
                let bridge = ctx.bridge
                let input = ctx.input

                let state = bridge.getState()
                let mirroringStatus: String
                switch state {
                case .connected:
                    let info = bridge.getWindowInfo()
                    let sizeDesc =
                        info.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "unknown"
                    let posDesc =
                        info.map { "pos=(\(Int($0.position.x)),\(Int($0.position.y)))" } ?? "pos=unknown"
                    let orientDesc = bridge.getOrientation()?.rawValue ?? "unknown"
                    mirroringStatus = "Connected — mirroring active (window: \(sizeDesc), \(posDesc), \(orientDesc))"
                case .paused:
                    mirroringStatus = "Paused — connection paused, can resume"
                case .notRunning:
                    mirroringStatus = "Not running — iPhone Mirroring app is not open"
                case .noWindow:
                    mirroringStatus = "No window — app is running but no mirroring window found"
                }

                // Check Karabiner helper status
                let helperStatusMsg: String
                if let status = input.helperStatus() {
                    let kb = status["keyboard_ready"] as? Bool ?? false
                    let pt = status["pointing_ready"] as? Bool ?? false
                    helperStatusMsg = "Helper: connected (keyboard=\(kb), pointing=\(pt))"
                } else {
                    helperStatusMsg = "Helper: not running (tap/type/swipe unavailable)"
                }

                return .text("\(mirroringStatus)\n\(helperStatusMsg)")
            }
        ))
    }
}
