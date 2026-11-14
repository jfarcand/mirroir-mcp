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
// ABOUTME: Runtime container for one app's simulator state — current screen, tap counter, fired obstacles.
// ABOUTME: Built from a SimulatorSpec parsed out of an APP.md file at FakeMirroring startup.

import Foundation
import HelperLib

/// Mutable per-app session state. The AppRegistry holds one of these per loaded app.
/// All access is single-threaded on the main thread (FakeMirroring is a UI app).
final class AppPack {
    /// The static scene declaration parsed from APP.md.
    let spec: SimulatorSpec
    /// Currently active screen ID. Initialized to `spec.rootScreenID`.
    private(set) var currentScreenID: String
    /// Number of taps the user has performed since the last force-quit/reset.
    /// Drives `after_n_taps` obstacle triggers.
    private(set) var tapCount: Int = 0
    /// IDs of obstacles that have already fired in this session.
    private(set) var firedObstacleIDs: Set<String> = []
    /// The currently visible obstacle, if any. Tapping any of its buttons clears it.
    private(set) var activeObstacle: SimulatorObstacle?
    /// Whether this pack has been "described" since launch — used to fire `on_first_describe`.
    private(set) var hasBeenDescribed: Bool = false

    init(spec: SimulatorSpec) {
        self.spec = spec
        self.currentScreenID = spec.rootScreenID
    }

    /// The currently active screen, or nil if `currentScreenID` is dangling.
    var currentScreen: SimulatorScreen? { spec.screens[currentScreenID] }

    /// Reset to the root screen and clear session state.
    /// Called when the app is force-quit via App Switcher.
    func resetToRoot() {
        currentScreenID = spec.rootScreenID
        tapCount = 0
        firedObstacleIDs = []
        activeObstacle = nil
        hasBeenDescribed = false
    }

    /// Navigate to a new screen, clearing any active obstacle as a side effect
    /// (the obstacle is dismissed implicitly when the user moves away).
    /// Increments the tap counter for `after_n_taps` triggers.
    func navigate(to screenID: String) {
        guard spec.screens[screenID] != nil else { return }
        currentScreenID = screenID
        tapCount += 1
        activeObstacle = nil
        maybeFireObstacle()
    }

    /// Mark this pack as "described" — fires any `on_first_describe` obstacle
    /// that hasn't fired yet. Idempotent across describes.
    func markDescribed() {
        let firstTime = !hasBeenDescribed
        hasBeenDescribed = true
        if firstTime { maybeFireObstacle() }
    }

    /// Dismiss the active obstacle (e.g., user tapped one of its buttons).
    func dismissActiveObstacle() {
        activeObstacle = nil
    }

    /// Fire the next eligible obstacle, if any. At most one obstacle is shown
    /// at a time; obstacles fire in declaration order.
    private func maybeFireObstacle() {
        guard activeObstacle == nil else { return }
        for obstacle in spec.obstacles {
            guard !firedObstacleIDs.contains(obstacle.id) else { continue }
            if shouldFire(obstacle) {
                firedObstacleIDs.insert(obstacle.id)
                activeObstacle = obstacle
                return
            }
        }
    }

    private func shouldFire(_ obstacle: SimulatorObstacle) -> Bool {
        switch obstacle.trigger {
        case .never: return false
        case .onFirstDescribe: return hasBeenDescribed
        case .afterTaps(let count): return tapCount >= count
        }
    }
}
