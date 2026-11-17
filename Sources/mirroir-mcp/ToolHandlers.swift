/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Orchestrates MCP tool registration by delegating to category-specific files.
// ABOUTME: Each tool category (screen, input, navigation, skill, info, automation) lives in its own file.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerTools(
        server: MCPServer,
        registry: TargetRegistry,
        policy: PermissionPolicy
    ) {
        server.setScreenReader { arguments in
            registry.resolveForTool(arguments).0?.ocrDescriber.describe()
        }
        registerScreenTools(server: server, registry: registry)
        registerInputTools(server: server, registry: registry, policy: policy)
        registerTapTools(server: server, registry: registry, policy: policy)
        registerTouchTools(server: server, registry: registry, policy: policy)
        registerGestureTools(server: server, registry: registry)
        registerHoldKeysTools(server: server, registry: registry)
        registerNavigationTools(server: server, registry: registry,
                                policy: policy)
        registerInfoTools(server: server, registry: registry, updateNotice: UpdateCheck.liveNotice)
        // get_skill marks the start screen of the skill save_compiled then saves.
        let compilationSession = CompilationSession()
        registerSkillTools(server: server, registry: registry, session: compilationSession)
        registerScrollToTools(server: server, registry: registry)
        registerAppManagementTools(server: server, registry: registry)
        registerMeasureTools(server: server, registry: registry)
        registerNetworkTools(server: server, registry: registry, policy: policy)
        registerTargetTools(server: server, registry: registry)
        registerNotesTools(server: server)
        registerListenTools(server: server, registry: registry)
        registerCompilationTools(server: server, registry: registry, session: compilationSession)
        registerGenerateSkillTools(server: server, registry: registry, policy: policy)
        registerComponentTools(server: server, registry: registry)
        registerRunStepsTools(server: server, registry: registry, policy: policy)
    }
}
