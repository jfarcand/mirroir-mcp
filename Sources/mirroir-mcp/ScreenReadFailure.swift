// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Words the error for a screen read that returned nothing, from the state the target's window is in.
// ABOUTME: A minimized window is named as the cause instead of asking whether the window is visible.

import Foundation
import HelperLib

/// The message for a screenshot or a screen description that could not be taken.
enum ScreenReadFailure {

    /// `what` failed (a full sentence), on the target named `targetName` whose
    /// window is in `state`. A minimized window shows nothing to read, and no
    /// read brings it back, so the message says who has to.
    static func message(_ what: String, targetName: String, state: WindowState) -> String {
        switch state {
        case .minimized:
            return "\(what) The '\(targetName)' window is minimized, so it shows nothing to read. "
                + "The user must bring it back from the Dock. " + AgentInstruction.waitForUser
        case .connected, .paused, .notRunning, .noWindow:
            return "\(what) Is the '\(targetName)' window visible?"
        }
    }
}
