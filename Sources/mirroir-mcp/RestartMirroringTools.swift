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
// ABOUTME: Registers restart_mirroring, which quits iPhone Mirroring, opens it again and waits for it to connect.
// ABOUTME: For input that stops landing (typed keys lost); it drops the session, so it needs consent.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerRestartMirroringTools(server: MCPServer, registry: TargetRegistry) {
        server.registerTool(MCPToolDefinition(
            name: "restart_mirroring",
            description: """
                Quit iPhone Mirroring on the Mac, open it again and wait until it is \
                connected. Use it when input stops landing: typed keys or taps that the \
                screen never shows, while describe_screen still reads it. It ends the \
                session and whatever the window showed, so ask the user first. An app \
                that is not running is not opened: when the user quit it, it stays quit. \
                When it opens but does not connect, the reply says what its window asks for.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "timeout": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Most seconds to wait for the session to connect again (default: 60)"),
                    ]),
                ]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                guard let bridge = ctx.bridge as? any MirroringRestartable else {
                    return .error("Target '\(ctx.name)' is not iPhone Mirroring: only iPhone Mirroring can be restarted")
                }
                var timing = MirroringRestart.Timing()
                if let value = args["timeout"] {
                    guard let seconds = value.asInt(), seconds >= 1 else {
                        return .error("timeout must be a whole number of seconds, at least 1")
                    }
                    timing.connectSeconds = Double(seconds)
                }
                let outcome = bridge.restart(timing: timing)
                let message = outcome.message(targetName: ctx.name)
                return outcome.succeeded ? .text(message) : .error(message)
            }
        ))
    }
}
