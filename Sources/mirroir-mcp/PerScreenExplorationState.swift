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
// ABOUTME: Per-screen runtime state for the exploration engine — scroll counts and tap-area deduplication.
// ABOUTME: Extracted from NavigationGraph so the core graph stays focused on nodes + edges + visited state.

import Foundation
import HelperLib

/// Owns per-screen runtime state that accumulates during an exploration session:
/// scroll count (how many times the explorer has scrolled this screen) and the
/// tap-area cache (which coordinates have already been tapped, with proximity
/// tolerance for deduplication).
///
/// Thread-safe internally — callers do not lock around individual mutations.
/// Lives as an owned collaborator on `NavigationGraph`; swapping it out for a
/// stricter dedup strategy (or disabling it in tests) is a one-liner.
final class PerScreenExplorationState: @unchecked Sendable {

    private let lock = NSLock()
    private var scrollCounts: [String: Int] = [:]
    private var tapCaches: [String: TapAreaCache] = [:]

    /// Reset all per-screen state. Called when the graph restarts.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        scrollCounts.removeAll()
        tapCaches.removeAll()
    }

    // MARK: - Scroll Count

    /// How many times the explorer has scrolled the given screen.
    func scrollCount(for fingerprint: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return scrollCounts[fingerprint, default: 0]
    }

    /// Increment the scroll count for a screen.
    func incrementScrollCount(for fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        scrollCounts[fingerprint, default: 0] += 1
    }

    // MARK: - Tap Area Cache

    /// Record a tap at the given coordinates on a screen.
    func recordTap(fingerprint: String, x: Double, y: Double) {
        lock.lock()
        defer { lock.unlock() }
        tapCaches[fingerprint, default: TapAreaCache()].record(x: x, y: y)
    }

    /// Whether a point was already tapped on a screen (within proximity radius).
    func wasAlreadyTapped(fingerprint: String, x: Double, y: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tapCaches[fingerprint]?.wasAlreadyTapped(x: x, y: y) ?? false
    }

    /// Number of tapped areas recorded for a screen.
    func tapCount(for fingerprint: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tapCaches[fingerprint]?.count ?? 0
    }
}
