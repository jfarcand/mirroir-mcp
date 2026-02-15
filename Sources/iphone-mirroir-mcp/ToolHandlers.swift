// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Orchestrates MCP tool registration by delegating to category-specific files.
// ABOUTME: Each tool category (screen, input, navigation, scenario, info) lives in its own file.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
    static func registerTools(
        server: MCPServer,
        bridge: any MirroringBridging,
        capture: any ScreenCapturing,
        recorder: any ScreenRecording,
        input: any InputProviding,
        describer: any ScreenDescribing,
        policy: PermissionPolicy
    ) {
        registerScreenTools(server: server, bridge: bridge, capture: capture,
                            recorder: recorder, describer: describer)
        registerInputTools(server: server, bridge: bridge, input: input)
        registerNavigationTools(server: server, bridge: bridge, input: input,
                                policy: policy)
        registerInfoTools(server: server, bridge: bridge, input: input,
                          capture: capture)
        registerScenarioTools(server: server)
    }
}
