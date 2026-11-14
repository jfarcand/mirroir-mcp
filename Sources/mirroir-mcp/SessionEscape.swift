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
// ABOUTME: Pluggable, target-agnostic strategies for escaping interruptions that block input.
// ABOUTME: SessionEscapeRegistry dispatches to ordered SessionEscapePlugins (iPhone Continuity dialog, resume overlay).

import CoreGraphics
import Foundation
import HelperLib

/// iPhone Mirroring escape: dismisses a Continuity dialog — e.g. "iPhone camera
/// is not available from Mac" (the Instagram Story camera trap) or any titled
/// OK/Resume prompt — by mouse-clicking its button. A real click frees the
/// session even when CGEvent input to the device is rejected and AX-press is
/// inert on the button. Applies only to mirroring targets (`MenuActionCapable`);
/// returns false (no-op) for other targets so it can share one registry.
struct ContinuityDialogEscape: SessionEscapePlugin {
    let id = "continuity-dialog"

    func attemptEscape(
        bridge: any WindowBridging, click: (CGPoint) -> Void, tag: String
    ) -> Bool {
        guard let mirroring = bridge as? MenuActionCapable,
              let point = mirroring.pausedDismissButtonPoint() else { return false }
        DebugLog.log(tag, "escape[\(id)]: mouse-clicking dismiss button at " +
            "screen=(\(Int(point.x)),\(Int(point.y)))")
        click(point)
        return true
    }
}

/// iPhone Mirroring escape: resumes the plain "click to resume" overlay (no
/// titled button) via AX-press. Tried after `ContinuityDialogEscape` so a precise
/// titled button wins first. No-op for non-mirroring targets.
struct ResumeOverlayEscape: SessionEscapePlugin {
    let id = "resume-overlay"

    func attemptEscape(
        bridge: any WindowBridging, click: (CGPoint) -> Void, tag: String
    ) -> Bool {
        guard let mirroring = bridge as? MenuActionCapable else { return false }
        DebugLog.log(tag, "escape[\(id)]: pressing Resume")
        return mirroring.pressResume()
    }
}

/// Ordered, target-agnostic registry of escape plugins. The first plugin that
/// acts wins; the caller re-checks the connection afterward. Register a plugin
/// here to handle a new target or interruption — no change to the input path
/// needed. Each plugin narrows the generic bridge to the capability it requires.
enum SessionEscapeRegistry {
    static let plugins: [SessionEscapePlugin] = [
        ContinuityDialogEscape(),
        ResumeOverlayEscape(),
    ]

    /// Run the first applicable plugin against the current interruption.
    /// Returns true if a plugin recognized the state and acted.
    static func attemptEscape(
        bridge: any WindowBridging, click: (CGPoint) -> Void, tag: String
    ) -> Bool {
        for plugin in plugins
        where plugin.attemptEscape(bridge: bridge, click: click, tag: tag) {
            return true
        }
        return false
    }
}
