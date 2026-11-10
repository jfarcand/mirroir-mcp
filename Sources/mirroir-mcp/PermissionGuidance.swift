// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
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

    /// The sentence telling the user how to grant `pane` to `hostApp`, the app
    /// that runs mirroir-mcp (nil when no ancestor process is an app).
    static func hint(_ pane: Pane, hostApp: String?) -> String {
        let app = hostApp.map { "\"\($0)\"" }
            ?? "the app that runs mirroir-mcp (your terminal, editor or AI client)"
        var text = "Open System Settings > Privacy & Security > \(pane.title) "
            + "(open \"\(pane.url)\") and turn on \(app)."
        if pane == .screenRecording {
            // The serve agent's bundle is a launchd job, not an app to quit.
            let restart = hostApp == ServeAppBundle.displayName
                ? "restart the agent (launchctl kickstart -k gui/$(id -u)/\(InstallAgentCommand.label))"
                : "quit and reopen \(hostApp ?? "that app")"
            text += " Then \(restart): Screen Recording takes effect only after a restart."
        }
        return text
    }
}
