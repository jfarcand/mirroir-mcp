// ABOUTME: Orchestrates MCP tool registration by delegating to category-specific files.
// ABOUTME: Each tool category (screen, input, navigation, scenario, info) lives in its own file.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
    static func registerTools(
        server: MCPServer,
        bridge: MirroringBridge,
        capture: ScreenCapture,
        recorder: ScreenRecorder,
        input: InputSimulation,
        describer: ScreenDescriber,
        policy: PermissionPolicy
    ) {
        registerScreenTools(server: server, bridge: bridge, capture: capture,
                            recorder: recorder, describer: describer)
        registerInputTools(server: server, bridge: bridge, input: input)
        registerNavigationTools(server: server, bridge: bridge, input: input,
                                policy: policy)
        registerInfoTools(server: server, bridge: bridge, input: input)
        registerScenarioTools(server: server)
    }
}
