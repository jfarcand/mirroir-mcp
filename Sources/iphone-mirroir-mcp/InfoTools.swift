// ABOUTME: Registers info-related MCP tools: get_orientation, status.
// ABOUTME: Each tool maps MCP JSON-RPC calls to the bridge for querying mirroring state.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
    static func registerInfoTools(
        server: MCPServer,
        bridge: MirroringBridge,
        input: InputSimulation
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
            handler: { _ in
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
            handler: { _ in
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
                let helperStatus: String
                if let status = input.helperClient.status() {
                    let kb = status["keyboard_ready"] as? Bool ?? false
                    let pt = status["pointing_ready"] as? Bool ?? false
                    helperStatus = "Helper: connected (keyboard=\(kb), pointing=\(pt))"
                } else {
                    helperStatus = "Helper: not running (tap/type/swipe unavailable)"
                }

                return .text("\(mirroringStatus)\n\(helperStatus)")
            }
        ))
    }
}
