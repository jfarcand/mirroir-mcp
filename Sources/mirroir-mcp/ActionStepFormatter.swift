// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Maps action type and arrivedVia pairs to markdown step text for SKILL.md.
// ABOUTME: Pure formatting function with no side effects.

/// Formats an exploration action into a markdown step string.
/// Maps action types (tap, swipe, type, etc.) to their display format.
enum ActionStepFormatter {

    /// Format an action step from actionType and arrivedVia.
    /// Returns nil if no action should be emitted (e.g. first screen with no arrivedVia).
    static func format(actionType: String?, arrivedVia: String?) -> String? {
        guard let arrivedVia = arrivedVia, !arrivedVia.isEmpty else {
            return nil
        }

        guard let actionType = actionType, !actionType.isEmpty else {
            // Default to tap when actionType is missing but arrivedVia is present
            return "Tap \"\(arrivedVia)\""
        }

        switch actionType {
        case "tap":
            return "Tap \"\(arrivedVia)\""
        case "swipe":
            return "swipe: \"\(arrivedVia)\""
        case "type":
            return "Type \"\(arrivedVia)\""
        case "press_key":
            return "Press **\(arrivedVia)**"
        case "scroll_to":
            return "Scroll until \"\(arrivedVia)\" is visible"
        case "long_press":
            return "long_press: \"\(arrivedVia)\""
        default:
            return "Tap \"\(arrivedVia)\""
        }
    }
}
