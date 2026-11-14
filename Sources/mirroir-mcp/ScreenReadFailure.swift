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
// ABOUTME: Words the error for a screen read that returned nothing, from the state the target's window is in.
// ABOUTME: A minimized window is named as the cause instead of asking whether the window is visible.

import Foundation
import HelperLib

/// The message for a screenshot or a screen description that could not be taken.
enum ScreenReadFailure {

    /// `what` failed (a full sentence), on the target named `targetName` whose
    /// window is in `state`. A minimized window shows nothing to read, and an
    /// app that is not running has no window; no read brings either back, so
    /// the message says who has to.
    static func message(_ what: String, targetName: String, state: WindowState) -> String {
        switch state {
        case .minimized:
            return "\(what) The '\(targetName)' window is minimized, so it shows nothing to read. "
                + "The user must bring it back from the Dock. " + AgentInstruction.waitForUser
        case .notRunning:
            return "\(what) '\(targetName)' is not running, so there is no screen to read. "
                + "The user must open iPhone Mirroring. " + AgentInstruction.waitForUser
        case .connected, .paused, .noWindow:
            return "\(what) Is the '\(targetName)' window visible?"
        }
    }
}
