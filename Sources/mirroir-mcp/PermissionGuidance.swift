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
// ABOUTME: The fix for a missing macOS privacy grant: which pane, which app to turn on, and the link that opens the pane.
// ABOUTME: Shared by doctor and check_health so both name the same app and the same restart rule.

import Foundation

/// What to tell the user when macOS has not granted a permission mirroir needs.
enum PermissionGuidance {

    /// A Privacy & Security pane in System Settings.
    enum Pane: CaseIterable {
        case screenRecording
        case accessibility

        /// The pane's name in System Settings > Privacy & Security.
        var title: String {
            switch self {
            case .screenRecording: return "Screen Recording"
            case .accessibility: return "Accessibility"
            }
        }

        /// The link that opens the pane directly (`open "<url>"`).
        var url: String {
            switch self {
            case .screenRecording:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            }
        }
    }

    /// The sentence telling the user how to grant `pane` to `grantee`, what
    /// holds this process's grants (nil when macOS names nothing usable).
    static func hint(_ pane: Pane, grantee: HostApp.Grantee?) -> String {
        let app = grantee.map { "\"\($0.displayName)\"" }
            ?? "the app that runs mirroir-mcp (your terminal, editor or AI client)"
        var text = "Open System Settings > Privacy & Security > \(pane.title) "
            + "(open \"\(pane.url)\") and turn on \(app)."
        if case .server = grantee {
            text += " If it is not listed, add it with the + button."
        }
        if pane == .screenRecording {
            text += " Then \(restart(grantee)): Screen Recording takes effect only after a restart."
        }
        return text
    }

    /// How a new Screen Recording grant reaches `grantee`.
    static func restart(_ grantee: HostApp.Grantee?) -> String {
        switch grantee {
        case .app(let name):
            return "quit and reopen \"\(name)\""
        case .serveAgent:
            // The serve agent's bundle is a launchd job, not an app to quit.
            return "restart the agent (launchctl kickstart -k gui/$(id -u)/\(InstallAgentCommand.label))"
        case .server:
            // The server answers for itself, so it restarts with the client that starts it.
            return "quit and reopen the app that started mirroir-mcp (your AI client)"
        case nil:
            return "quit and reopen the app that runs mirroir-mcp"
        }
    }
}
