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
// ABOUTME: Unit tests for RunningAppLocator's live process-lookup contract.
// ABOUTME: Covers unknown identifiers and the liveness guarantee every lookup must hold.

import AppKit
import XCTest
@testable import mirroir_mcp

/// The locator exists so a long-lived server never hands a dead PID to the AX
/// APIs (issue #34). These tests pin the two halves of that contract: nothing is
/// invented for identifiers that are not running, and everything returned is a
/// process that still exists right now.
final class RunningAppLocatorTests: XCTestCase {

    // MARK: - Unknown identifiers

    func testUnknownBundleIDReturnsNil() {
        XCTAssertNil(
            RunningAppLocator.byBundleID("com.jfarcand.mirroir.test.no-such-app"),
            "A bundle ID that is not running must not resolve to a process")
    }

    func testEmptyBundleIDReturnsNil() {
        XCTAssertNil(
            RunningAppLocator.byBundleID(""),
            "An empty bundle ID must not match an arbitrary process")
    }

    func testUnknownLocalizedNameReturnsNil() {
        XCTAssertNil(
            RunningAppLocator.byLocalizedName("No Such Application 4f1c9e"),
            "A localized name that is not running must not resolve to a process")
    }

    // MARK: - Liveness

    /// Every instance the locator returns must be a live process. A terminated
    /// instance is precisely what strands `getState()` at `.noWindow`: its PID is
    /// dead, so `AXUIElementCreateApplication` fails for the rest of the server's
    /// lifetime.
    func testBundleIDLookupOnlyReturnsLiveProcesses() throws {
        let bundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        XCTAssertFalse(bundleIDs.isEmpty, "Expected at least one running app with a bundle ID")

        var resolved = 0
        for bundleID in bundleIDs {
            // nil is legitimate: an app listed in the snapshot may have exited
            // since. What must never happen is resolving to a dead process.
            guard let app = RunningAppLocator.byBundleID(bundleID) else { continue }
            resolved += 1
            XCTAssertEqual(app.bundleIdentifier, bundleID, "Lookup returned a different app")
            XCTAssertFalse(app.isTerminated, "\(bundleID) resolved to a terminated instance")
            XCTAssertNotNil(
                NSRunningApplication(processIdentifier: app.processIdentifier),
                "\(bundleID) resolved to PID \(app.processIdentifier), which is not a live process")
        }
        XCTAssertGreaterThan(resolved, 0, "No running app resolved — the lookup is not working")
    }

    /// The frontmost lookup reads the window server on every call, so whatever it
    /// names must exist right now. nil is legitimate — no normal-layer window may
    /// be on screen — but a terminated process never is.
    func testFrontmostWindowOwnerIsLive() throws {
        guard let front = RunningAppLocator.frontmostWindowOwner() else { return }
        XCTAssertFalse(front.isTerminated, "Frontmost owner resolved to a terminated instance")
        XCTAssertNotNil(
            NSRunningApplication(processIdentifier: front.processIdentifier),
            "Frontmost owner PID \(front.processIdentifier) is not a live process")
    }

    /// The lookup must name the owner of the frontmost normal-layer window, which
    /// is the question `NSWorkspace.frontmostApplication` answers from a snapshot
    /// that never refreshes in the server.
    func testFrontmostWindowOwnerMatchesTheWindowServer() throws {
        let expected = WindowListHelper.frontmostWindowOwnerPID()
        XCTAssertEqual(
            RunningAppLocator.frontmostWindowOwner()?.processIdentifier, expected,
            "Frontmost owner disagreed with the window server's front-to-back order")
    }

    /// The name path re-resolves its snapshot match by PID, so it too can only
    /// return a process that exists.
    func testLocalizedNameLookupOnlyReturnsLiveProcesses() throws {
        let names = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        XCTAssertFalse(names.isEmpty, "Expected at least one running app with a localized name")

        var resolved = 0
        for name in names {
            guard let app = RunningAppLocator.byLocalizedName(name) else { continue }
            resolved += 1
            XCTAssertEqual(app.localizedName, name, "Lookup returned a differently named app")
            XCTAssertFalse(app.isTerminated, "\(name) resolved to a terminated instance")
            XCTAssertNotNil(
                NSRunningApplication(processIdentifier: app.processIdentifier),
                "\(name) resolved to PID \(app.processIdentifier), which is not a live process")
        }
        XCTAssertGreaterThan(resolved, 0, "No running app resolved — the lookup is not working")
    }
}
