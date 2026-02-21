// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Orchestrates MCP tool registration by delegating to category-specific files.
// ABOUTME: Each tool category (screen, input, navigation, scenario, info, automation) lives in its own file.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerTools(
        server: MCPServer,
        registry: TargetRegistry,
        policy: PermissionPolicy
    ) {
        registerScreenTools(server: server, registry: registry)
        registerInputTools(server: server, registry: registry)
        registerNavigationTools(server: server, registry: registry,
                                policy: policy)
        registerInfoTools(server: server, registry: registry)
        registerScenarioTools(server: server)
        registerScrollToTools(server: server, registry: registry)
        registerAppManagementTools(server: server, registry: registry)
        registerMeasureTools(server: server, registry: registry)
        registerNetworkTools(server: server, registry: registry)
        registerTargetTools(server: server, registry: registry)
        registerCompilationTools(server: server, registry: registry)
    }
}
