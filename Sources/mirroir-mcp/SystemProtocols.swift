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
// ABOUTME: System-boundary protocols for macOS services around a run: privacy panes and grants, display power.
// ABOUTME: Tests stand these in; the live implementations open System Settings, spawn processes, call IOKit.

import Foundation

// MARK: - Privacy Grants

/// System Settings' Privacy & Security panes and what a new process is granted.
///
/// A running process caches its Screen Recording answer until it restarts, so
/// whether a grant has been given is only known by asking a fresh process.
protocol PrivacyGrantChecking: Sendable {
    /// Open `pane` in System Settings; false when it could not be opened.
    func open(_ pane: PermissionGuidance.Pane) -> Bool

    /// The panes a freshly started process is granted, or nil when the
    /// probe could not run.
    func grantedToFreshProcess() -> Set<PermissionGuidance.Pane>?
}

// MARK: - Display Power

/// A power assertion that keeps the Mac's display awake, so neither display
/// sleep nor the screen saver covers the mirror while a run is acting on it.
/// A lock the user triggers still wins.
protocol DisplayAwakeAsserting: Sendable {
    /// Start keeping the display awake, naming why for `pmset -g assertions`.
    /// Returns the assertion to release, or nil when macOS refused it.
    func assertAwake(reason: String) -> UInt32?

    /// Stop the assertion `assertAwake` returned.
    func release(_ assertion: UInt32)
}
