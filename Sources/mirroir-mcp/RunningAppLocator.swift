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
// ABOUTME: Live process lookup for window bridges, independent of the main run loop.
// ABOUTME: Replaces NSWorkspace's snapshot, which freezes in the stdio MCP server.

import AppKit

/// Locates running applications from live system state.
///
/// `NSWorkspace.shared.runningApplications` is only updated when the main run
/// loop runs in a common mode. The MCP server spends its entire lifetime
/// blocked in `readLine()`, so that snapshot freezes at whatever the process
/// last observed. When the target app relaunches — an iPhone respring restarts
/// ScreenContinuity — the frozen snapshot keeps the terminated instance and its
/// dead PID, and reports `isTerminated == false` for it because that property is
/// refreshed by the same run loop. Every AX call against the dead PID then fails
/// with `kAXErrorCannotComplete`, which a bridge reports as `.noWindow` for the
/// rest of the server's lifetime; nothing short of restarting the server clears
/// it, and quitting the target app does not help.
///
/// Launch Services answers from live state, so these lookups stay correct across
/// target restarts without any run loop trip.
enum RunningAppLocator {

    /// The running application with `bundleID`, or nil when none is running.
    static func byBundleID(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }
    }

    /// The running application whose localized name is `name`, or nil.
    ///
    /// Launch Services offers no lookup by name, so apps without a bundle
    /// identifier (QEMU-based emulators) are matched against the NSWorkspace
    /// snapshot and then re-resolved by PID: `NSRunningApplication(processIdentifier:)`
    /// reads live state and returns nil for a process that has exited, so a
    /// frozen snapshot can no longer hand back a dead PID. The name is checked
    /// again on the re-resolved instance in case the PID was recycled.
    /// Discovering a process that launched *after* the snapshot froze is left to
    /// the caller's CGWindowList scan (`GenericWindowBridge.findWindowInList`),
    /// which is itself live.
    static func byLocalizedName(_ name: String) -> NSRunningApplication? {
        guard let candidate = NSWorkspace.shared.runningApplications.first(
            where: { $0.localizedName == name })
        else { return nil }
        let live = NSRunningApplication(processIdentifier: candidate.processIdentifier)
        return live?.localizedName == name ? live : nil
    }

    /// The application owning the frontmost normal-layer window, or nil.
    ///
    /// `NSWorkspace.shared.frontmostApplication` answers this from the same
    /// frozen snapshot as `runningApplications`: measured naming the wrong app
    /// in both directions of a focus switch in a process that never pumps its
    /// run loop, which is how focus debug logs came to point at whatever
    /// happened to be front at the last run loop trip. The window server's
    /// on-screen list is live.
    ///
    /// To ask whether one specific app is frontmost, prefer `isActive` on an
    /// instance from `byBundleID` — freshly resolved instances report live
    /// activation state, and that answer is not affected by window layering.
    static func frontmostWindowOwner() -> NSRunningApplication? {
        WindowListHelper.frontmostWindowOwnerPID()
            .flatMap { NSRunningApplication(processIdentifier: $0) }
    }
}
