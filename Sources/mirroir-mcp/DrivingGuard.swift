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
// ABOUTME: While driving mode is on, reads the phone's screen before each input and refuses it on a navigation screen.
// ABOUTME: The phone may be guiding the drive or change screens by itself, so each input looks first, right before it is sent.

import Foundation
import HelperLib

/// The check driving mode (`DrivingRules`) puts in front of every input. The
/// phone is on CarPlay and changes screens by itself, so the screen is read
/// right before the input, never trusted from an earlier read. An input is
/// refused when that read shows turn-by-turn navigation, unless it only
/// leaves that screen, or when the read cannot be made.
/// Which apps may open is `PermissionPolicy.checkAppLaunch`'s part.
enum DrivingGuard {

    /// Mutating tools that send nothing to the phone.
    static let offPhoneTools: Set<String> = ["save_note", "record_step", "save_compiled", "switch_target"]

    /// Tools that check each of their steps instead (`InlineStepRunner`).
    static let stepByStepTools: Set<String> = ["run_steps"]

    /// Tools that leave the screen without touching it, so a navigation screen
    /// does not stop them: CarPlay keeps its own scene and goes on guiding
    /// while the phone shows another app (measured parked, Waze, 2026-11-16).
    /// `launch_app` still opens only the apps driving mode lists.
    static let leaveScreenTools: Set<String> = ["press_home", "launch_app"]

    /// Tools refused outright while driving: an exploration sends many inputs
    /// with no check in front of each one.
    static let refusedTools: Set<String> = ["generate_skill"]

    /// Fragments of a navigation screen: `## Navigation` in `system-phrases.md`.
    static var navigationPhrases: [String] { SystemPhrases.live.phrases(.navigation) }

    /// Whether a call to `tool` sends input to the phone, so driving mode checks it.
    static func sendsInput(_ tool: String) -> Bool {
        !PermissionPolicy.readonlyTools.contains(tool) && !offPhoneTools.contains(tool)
            && !stepByStepTools.contains(tool)
    }

    /// Whether `elements` show a turn-by-turn navigation screen.
    static func showsNavigation(_ elements: [TapPoint]) -> Bool {
        let phrases = navigationPhrases
        return elements.contains { element in
            let text = SystemPhrases.fold(element.text)
            return phrases.contains { SystemPhrases.matches(text, pattern: $0) }
        }
    }

    /// Why a call to `tool` is refused while driving, or nil when it may run:
    /// driving mode is off, the tool sends no input, or `read` shows a screen
    /// with no navigation on it. `read` is called only when the check needs it.
    static func refusal(
        tool: String, policy: PermissionPolicy, read: () -> ScreenDescriber.DescribeResult?
    ) -> String? {
        guard policy.driving != nil, sendsInput(tool) else { return nil }
        if refusedTools.contains(tool) {
            return "'\(tool)' does not run while driving: it sends many inputs without reading the "
                + "screen before each one. \(stop)"
        }
        guard let screen = read(), screen.ocrFailure == nil else {
            return "Driving mode is on and the phone's screen could not be read, so '\(tool)' was not sent. \(stop)"
        }
        if showsNavigation(screen.elements), !leaveScreenTools.contains(tool) {
            return "Driving mode is on and the phone shows navigation, so '\(tool)' was not sent: "
                + "the phone is guiding the drive. \(stop)"
        }
        return nil
    }

    /// What every refusal ends with.
    private static let stop = "No input was sent. Driving mode is switched off in \(PermissionPolicy.configPath). "
        + AgentInstruction.userDecides
}
