// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The operations that exist only on some targets, and the one refusal a target without one gives.
// ABOUTME: A target declares its set in its profile; tool handlers and the step executor both refuse through here.

import Foundation
import HelperLib

/// An operation that exists only on some targets: each one drives something
/// the iPhone has and a Mac window does not. Raw values are the MCP tool names.
///
/// An operation a target lacks is refused, never emulated: sending the iOS
/// shortcut into a Mac app would do something else there.
enum TargetOperation: String, Sendable, CaseIterable {
    case launchApp = "launch_app"
    case openURL = "open_url"
    case pressHome = "press_home"
    case pressAppSwitcher = "press_app_switcher"
    case spotlight
    case resetApp = "reset_app"
    case setNetwork = "set_network"
    case shake

    /// What the operation relies on, completing the sentence "it ...".
    var requirement: String {
        switch self {
        case .launchApp: return "it launches apps through iPhone Spotlight"
        case .openURL: return "it opens the URL in Safari on the iPhone"
        case .pressHome: return "it presses iPhone Mirroring's Home Screen command"
        case .pressAppSwitcher: return "it presses iPhone Mirroring's App Switcher command"
        case .spotlight: return "it presses iPhone Mirroring's Spotlight command"
        case .resetApp: return "it force-quits through the iPhone App Switcher"
        case .setNetwork: return "it toggles the iPhone's network settings"
        case .shake:
            return "it sends the iOS shake shortcut (Ctrl+Cmd+Z), which this app would take "
                + "as a shortcut of its own"
        }
    }

    /// The operation a skill step performs, or nil when the step runs on every target.
    init?(step: SkillStep) {
        self.init(rawValue: InlineStepRunner.toolName(of: step))
    }
}

extension TargetProfile {

    /// Whether `operation` exists on this target.
    func supports(_ operation: TargetOperation) -> Bool {
        operations.contains(operation)
    }

    /// The operations this target lacks, by tool name.
    var unsupportedOperations: [TargetOperation] {
        TargetOperation.allCases.filter { !supports($0) }.sorted { $0.rawValue < $1.rawValue }
    }

    /// Why `operation` is refused on the target named `targetName`, or nil
    /// when the target has it. `supportedOn` names the configured targets that do.
    func refusal(of operation: TargetOperation, targetName: String, supportedOn: [String]) -> String? {
        guard !supports(operation) else { return nil }
        let elsewhere = supportedOn.isEmpty
            ? "No configured target supports it."
            : "Supported on: \(supportedOn.sorted().joined(separator: ", "))."
        return "\(operation.rawValue) is unsupported on target '\(targetName)' (\(displayName)): "
            + "\(operation.requirement). Nothing was sent. \(elsewhere)"
    }
}
