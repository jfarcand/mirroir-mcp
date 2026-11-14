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
// ABOUTME: State machine + frontier queue for BFSExplorer — phase transitions, action counter, viewport tracking.
// ABOUTME: Replaces a grab-bag of mutually-entangled fields that were poked from four sibling extension files.

import Foundation
import HelperLib

/// Owns BFSExplorer's frontier queue, phase state machine, per-screen action
/// counter, and viewport tracker. Extraction collapses what were six entangled
/// fields (`frontier`, `frontierIndex`, `phase`, `actionsOnCurrentScreen`,
/// `currentViewportIndex`, `totalViewpoints`) into one collaborator with a
/// single responsibility: orchestrating the breadth-first exploration cycle.
///
/// Thread-safety: all mutations go through the internal lock. Callers do not
/// need to lock around individual property accesses.
final class FrontierManager: @unchecked Sendable {

    private let lock = NSLock()
    private var _frontier: [FrontierScreen] = []
    private var _frontierIndex: Int = 0
    private var _phase: BFSPhase = .atRoot
    private var _actionsOnCurrentScreen: Int = 0
    private var _currentViewportIndex: Int = 0
    private var _totalViewpoints: Int = 0

    // MARK: - Phase

    var phase: BFSPhase {
        get { lock.withLock { _phase } }
        set { lock.withLock { _phase = newValue } }
    }

    // MARK: - Frontier Queue

    /// Seed the frontier with a single root screen and reset the queue cursor.
    func seed(_ root: FrontierScreen) {
        lock.lock()
        defer { lock.unlock() }
        _frontier = [root]
        _frontierIndex = 0
    }

    /// Append a newly discovered frontier screen for later exploration.
    func enqueue(_ screen: FrontierScreen) {
        lock.lock()
        defer { lock.unlock() }
        _frontier.append(screen)
    }

    /// Pop the next frontier screen or return nil if exhausted. Also resets
    /// `actionsOnCurrentScreen` since a new screen means a fresh action budget.
    ///
    /// Deep-lineage screens (reached through an APP.md `## Deep Tabs` tab) are
    /// preferred over FIFO order: the first unconsumed deep-lineage entry is
    /// swapped to the cursor position, so a declared deep subtree is explored
    /// before sibling breadth. With no deep-lineage entries pending — the
    /// universal case for apps without a `## Deep Tabs` section — dequeue
    /// order is plain FIFO, unchanged.
    func dequeueNext() -> FrontierScreen? {
        lock.lock()
        defer { lock.unlock() }
        guard _frontierIndex < _frontier.count else { return nil }
        let cursor = _frontier[_frontierIndex]
        if cursor.depth > 0, !cursor.isDeepLineage,
           let deepIndex = _frontier[_frontierIndex...].firstIndex(where: { $0.isDeepLineage }) {
            // Move (not swap) the deep entry to the cursor so the remaining
            // breadth entries keep their relative FIFO order. The root seed
            // (depth 0) is never jumped — exploration always starts there.
            let deep = _frontier.remove(at: deepIndex)
            _frontier.insert(deep, at: _frontierIndex)
        }
        let target = _frontier[_frontierIndex]
        _frontierIndex += 1
        _actionsOnCurrentScreen = 0
        return target
    }

    /// Current position + length for debug logs (e.g. "dequeue frontier[2/5]").
    var progress: (index: Int, total: Int) {
        lock.withLock { (_frontierIndex - 1, _frontier.count) }
    }

    // MARK: - Action Budget

    var actionsOnCurrentScreen: Int {
        lock.withLock { _actionsOnCurrentScreen }
    }

    func incrementActionsOnCurrentScreen() {
        lock.withLock { _actionsOnCurrentScreen += 1 }
    }

    func resetActionsOnCurrentScreen() {
        lock.withLock { _actionsOnCurrentScreen = 0 }
    }

    // MARK: - Viewport Tracking

    var currentViewportIndex: Int {
        lock.withLock { _currentViewportIndex }
    }

    var totalViewpoints: Int {
        lock.withLock { _totalViewpoints }
    }

    /// Reset the viewport counters at the start of calibration.
    func resetViewports(total: Int) {
        lock.lock()
        defer { lock.unlock() }
        _totalViewpoints = total
        _currentViewportIndex = 0
    }

    /// Advance to the next viewport when the current one is exhausted.
    func advanceViewport() {
        lock.withLock { _currentViewportIndex += 1 }
    }
}

private extension NSLock {
    /// Swift-native `withLock` helper — avoids explicit `lock()` / `defer { unlock() }`.
    @inline(__always)
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
