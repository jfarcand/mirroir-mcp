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
// ABOUTME: Depth-first exploration stack + action counter — owns the backtrack-stack state for DFSExplorer.
// ABOUTME: Thread-safe; replaces scattered pokes at DFSExplorer.backtrackStack + actionsOnCurrentScreen.

import Foundation
import HelperLib

/// Owns DFSExplorer's backtrack stack and per-screen action counter. Extraction
/// collapses what were two intertwined mutable fields (`backtrackStack`,
/// `actionsOnCurrentScreen`) into a single collaborator with explicit methods
/// for push/pop/truncate operations. Thread-safe via an internal NSLock.
final class DepthTracker: @unchecked Sendable {

    private let lock = NSLock()
    private var _stack: [String] = []
    private var _actionsOnCurrentScreen: Int = 0

    // MARK: - Lifecycle

    /// Seed the stack with the root screen's fingerprint at depth 0.
    func seed(rootFP: String) {
        lock.lock()
        defer { lock.unlock() }
        _stack = [rootFP]
        _actionsOnCurrentScreen = 0
    }

    // MARK: - Stack Access

    /// Current exploration depth (0 = at root).
    var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stack.count - 1
    }

    /// Total number of entries on the backtrack stack (including root).
    var stackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stack.count
    }

    /// Fingerprint at the top of the stack (i.e., current screen), or nil if empty.
    var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return _stack.last
    }

    /// Immutable snapshot of the current stack for read-only consumers.
    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _stack
    }

    // MARK: - Mutations

    /// Push a newly discovered screen onto the stack and reset the action counter.
    func push(_ fp: String) {
        lock.lock()
        defer { lock.unlock() }
        _stack.append(fp)
        _actionsOnCurrentScreen = 0
    }

    /// Pop the top of the stack and reset the action counter. Returns the
    /// popped fingerprint, or nil if the stack is empty.
    @discardableResult
    func popOne() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !_stack.isEmpty else { return nil }
        let popped = _stack.removeLast()
        _actionsOnCurrentScreen = 0
        return popped
    }

    /// Truncate the stack so the last occurrence of `fp` becomes the top.
    /// Used when the explorer matches an older fingerprint and needs to sync
    /// the stack with the actual navigation state. Returns true if `fp` was
    /// found (and the stack was truncated), false otherwise.
    @discardableResult
    func truncateToLastMatching(_ fp: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = _stack.lastIndex(of: fp) else { return false }
        while _stack.count > idx + 1 { _stack.removeLast() }
        _actionsOnCurrentScreen = 0
        return true
    }

    // MARK: - Action Counter

    var actionsOnCurrentScreen: Int {
        lock.lock()
        defer { lock.unlock() }
        return _actionsOnCurrentScreen
    }

    func incrementActionsOnCurrentScreen() {
        lock.lock()
        defer { lock.unlock() }
        _actionsOnCurrentScreen += 1
    }

    func resetActionsOnCurrentScreen() {
        lock.lock()
        defer { lock.unlock() }
        _actionsOnCurrentScreen = 0
    }
}
