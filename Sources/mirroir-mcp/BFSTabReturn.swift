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
// ABOUTME: Tab-aware backtrack helpers — resolves and taps the app's root tab for .tab edges.
// ABOUTME: Stateless enum namespace used by BFSBacktrackVerifier; icon-only bars resolve geometrically.

import CoreGraphics
import Foundation
import HelperLib

/// Tab-aware return-to-root helpers for BFS backtracking. When the edge that
/// led to the current screen was a tab switch, the correct reverse action is
/// tapping the app's root tab (the first APP.md-declared tab) — not the back
/// chevron, which icon-only tab roots (Instagram) do not have.
/// Pure transformation: all static methods, no stored state.
enum BFSTabReturn {

    /// Resolve the root-tab tap point for the given screen. Combines the
    /// screen's OCR elements with its detected icons so icon-only bars
    /// resolve via geometric anchor synthesis. Nil when no APP.md tabs are
    /// declared or the screen shows no tab-bar evidence.
    static func returnTarget(
        appDescription: AppDescription?,
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        windowSize: CGSize
    ) -> TapPoint? {
        guard let appDescription, !appDescription.tabs.isEmpty else { return nil }
        return TabTargetInjector.returnToRootTarget(
            tabs: appDescription.tabs, tabLayout: appDescription.tabLayout,
            elements: elements, icons: icons, windowSize: windowSize
        )
    }

    /// Tap the root tab on the current screen. Returns false when no root-tab
    /// target resolves (no APP.md tabs or no bar evidence) — the caller falls
    /// back to chevron-based tapBack.
    static func tapRootTab(
        appDescription: AppDescription?,
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        windowSize: CGSize,
        input: InputProviding
    ) -> Bool {
        guard let target = returnTarget(
            appDescription: appDescription, elements: elements,
            icons: icons, windowSize: windowSize
        ) else { return false }
        DebugLog.log("bfs", "tab return: tapping root tab at " +
            "(\(Int(target.tapX)),\(Int(target.tapY)))")
        _ = input.tap(x: target.tapX, y: target.tapY)
        usleep(EnvConfig.stepSettlingDelayMs * 1000)
        return true
    }

    /// Whether a screen's hints carry tab-root evidence: a tab-bar hint is
    /// present and no back chevron was detected. Feed content churns between
    /// visits, so a .tab return can land on the tab root with a different
    /// fingerprint — the visible tab bar plus the absent back chevron is
    /// accepted as being at root. The caller must evaluate this on the FIRST
    /// OCR after the return tap (before any recovery taps, which would
    /// navigate away) and must reject it when the screen structurally matches
    /// a known non-root node: a tab bar is visible on every tab screen, so
    /// this evidence cannot discriminate which tab is showing.
    static func showsTabRootEvidence(hints: [String]) -> Bool {
        let hasTabBarHint = hints.contains {
            $0.hasPrefix(NavigationHintDetector.tabBarHintPrefix)
        }
        let hasBackChevron = hints.contains { $0.contains("Back navigation") }
        return hasTabBarHint && !hasBackChevron
    }
}
