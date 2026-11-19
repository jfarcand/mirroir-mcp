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
// ABOUTME: Tests for PointCoverage over window lists shaped like ones measured on a real Mac.
// ABOUTME: Pins that the Dock's display-sized overlay is ignored, a banner over the point is waited out, and a covering window refuses.

import CoreGraphics
import Foundation
import XCTest
@testable import mirroir_mcp

final class PointCoverageTests: XCTestCase {

    private let display = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    private let mirror = CGRect(x: 1280, y: 64, width: 430, height: 942)
    private let mirrorPID: pid_t = 100
    private let dockPID: pid_t = 200
    private let bannerPID: pid_t = 300
    private let otherPID: pid_t = 400
    /// A point inside the mirroring window, near its top-right.
    private let point = CGPoint(x: 1600, y: 120)

    private func entry(_ pid: pid_t, _ bounds: CGRect, layer: Int = 0,
                       name: String? = nil) -> WindowListEntry {
        WindowListEntry(windowID: CGWindowID(pid), ownerPID: pid, name: nil,
                        bounds: bounds, ownerName: name, layer: layer)
    }

    /// `ownerAtPoint` is what Accessibility reports at the point: the banner
    /// by default, as when the banner sits over it.
    private func verdict(_ entries: [WindowListEntry],
                         ownerAtPoint: pid_t? = nil) -> PointCoverageVerdict {
        PointCoverage.verdict(entries: entries, targetPID: mirrorPID, point: point,
                              displays: [display],
                              isTransientOverlay: { $0 == self.bannerPID },
                              ownerAtPoint: { ownerAtPoint ?? self.bannerPID })
    }

    private var bannerOverlay: [WindowListEntry] {
        [entry(bannerPID, display, layer: 21), entry(dockPID, display, layer: 20),
         entry(mirrorPID, mirror)]
    }

    /// Measured 2026-11-03: the Dock owns a display-sized layer-20 window in
    /// front of every app window, always.
    func testTheDocksDisplaySizedOverlayIsIgnored() {
        XCTAssertEqual(verdict([entry(dockPID, display, layer: 20, name: "Dock"),
                                entry(mirrorPID, mirror)]), .clear)
    }

    /// Measured 2026-11-03: a banner adds a display-sized Notification Center
    /// window at layer 21 for about five seconds.
    func testABannerOverThePointIsReportedAsTransient() {
        XCTAssertEqual(verdict(bannerOverlay), .transientOverlay(ownerPID: bannerPID))
    }

    /// GitHub #86: a banner in one corner blocked every tap on a mirror in the
    /// middle of the screen. Its display-sized window lets clicks through
    /// outside the banner, so the mirror owns the point and the click goes.
    func testABannerAwayFromThePointDoesNotHoldTheClick() {
        XCTAssertEqual(verdict(bannerOverlay, ownerAtPoint: mirrorPID), .clear)
    }

    /// With a banner up and the point owned by another app's window, the
    /// window list still decides: that window covers the point.
    func testABannerAwayFromThePointLeavesACoveringWindowCovering() {
        let chrome = CGRect(x: 1000, y: 50, width: 700, height: 600)
        let entries = [entry(bannerPID, display, layer: 21),
                       entry(otherPID, chrome, name: "Google Chrome"), entry(mirrorPID, mirror)]
        XCTAssertEqual(verdict(entries, ownerAtPoint: otherPID),
                       .covered(ownerPID: otherPID, ownerName: "Google Chrome"))
    }

    /// When Accessibility cannot say who holds the point, the banner is
    /// waited out as if it were over it: no click on an unknown banner.
    func testAnUnreadableOwnerAtThePointWaitsOutTheBanner() {
        let verdict = PointCoverage.verdict(
            entries: bannerOverlay, targetPID: mirrorPID, point: point, displays: [display],
            isTransientOverlay: { $0 == self.bannerPID }, ownerAtPoint: { nil })
        XCTAssertEqual(verdict, .transientOverlay(ownerPID: bannerPID))
    }

    /// Accessibility is asked only when a banner overlay is in front.
    func testTheOwnerAtThePointIsNotAskedWithoutABanner() {
        var asked = false
        _ = PointCoverage.verdict(
            entries: [entry(dockPID, display, layer: 20), entry(mirrorPID, mirror)],
            targetPID: mirrorPID, point: point, displays: [display],
            isTransientOverlay: { $0 == self.bannerPID }, ownerAtPoint: { asked = true; return nil })
        XCTAssertFalse(asked)
    }

    func testAFloatingPanelOverThePointCovers() {
        let panel = CGRect(x: 1500, y: 80, width: 300, height: 200)
        XCTAssertEqual(verdict([entry(otherPID, panel, layer: 3, name: "Picture in Picture"),
                                entry(mirrorPID, mirror)]),
                       .covered(ownerPID: otherPID, ownerName: "Picture in Picture"))
    }

    func testANormalWindowInFrontOverThePointCovers() {
        let chrome = CGRect(x: 1000, y: 50, width: 700, height: 600)
        XCTAssertEqual(verdict([entry(otherPID, chrome, name: "Google Chrome"),
                                entry(mirrorPID, mirror)]),
                       .covered(ownerPID: otherPID, ownerName: "Google Chrome"))
    }

    func testAWindowInFrontThatMissesThePointIsClear() {
        let elsewhere = CGRect(x: 0, y: 500, width: 600, height: 400)
        XCTAssertEqual(verdict([entry(otherPID, elsewhere), entry(mirrorPID, mirror)]), .clear)
    }

    func testWindowsBehindTheTargetDoNotCount() {
        let finder = CGRect(x: 196, y: 66, width: 1326, height: 957)
        XCTAssertEqual(verdict([entry(mirrorPID, mirror), entry(otherPID, finder)]), .clear)
    }

    func testNegativeLayerDesktopWidgetsDoNotCount() {
        let widget = CGRect(x: 1324, y: 42, width: 360, height: 360)
        XCTAssertEqual(verdict([entry(otherPID, widget, layer: -2_147_483_601),
                                entry(mirrorPID, mirror)]), .clear)
    }

    /// A menu-bar sliver is layer > 0 but not display-sized: over the point it covers.
    func testANonDisplaySizedSystemWindowOverThePointCovers() {
        let sliver = CGRect(x: 0, y: 100, width: 1710, height: 34)
        XCTAssertEqual(verdict([entry(otherPID, sliver, layer: 24), entry(mirrorPID, mirror)]),
                       .covered(ownerPID: otherPID, ownerName: nil))
    }

    func testNoTargetWindowUnderThePointCannotBeJudged() {
        XCTAssertEqual(verdict([entry(otherPID, display)]), .targetNotUnderPoint)
    }

    /// Measured 2026-11-03: the mirroring window was moved to x=10108, off
    /// every display, and a click posted there reached nothing.
    func testAWindowMovedOffEveryDisplayIsOffDisplay() {
        let offScreen = CGRect(x: 10108, y: 64, width: 430, height: 942)
        let verdict = PointCoverage.verdict(
            entries: [entry(mirrorPID, offScreen)], targetPID: mirrorPID,
            point: CGPoint(x: 10200, y: 120), displays: [display], isTransientOverlay: { _ in false }, ownerAtPoint: { nil })
        XCTAssertEqual(verdict, .offDisplay)
    }

    func testAnUnreadableDisplayListDoesNotBlockTheClick() {
        let verdict = PointCoverage.verdict(
            entries: [entry(mirrorPID, mirror)], targetPID: mirrorPID, point: point,
            displays: [], isTransientOverlay: { _ in false }, ownerAtPoint: { nil })
        XCTAssertEqual(verdict, .clear)
    }
}
