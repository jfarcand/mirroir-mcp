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
// ABOUTME: Tests BlockedAppTapGuard: a tap on a blocked app's labelled icon is refused on the Home Screen and in Spotlight.
// ABOUTME: Elements are OCR reads of an XR Home Screen page (French UI); the policy is the real PermissionPolicy.

import CoreGraphics
import XCTest
import HelperLib
@testable import mirroir_mcp

final class BlockedAppTapGuardTests: XCTestCase {

    private let height = 942.0

    private func el(_ text: String, _ x: Double, _ y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.9)
    }

    /// The XR's Home Screen page (2026-11-16): icons above their labels, the search pill at the bottom.
    private var home: [TapPoint] {
        [el("Calendrier", 233, 184), el("Appareil photo", 357, 184),
         el("Horloge", 263, 289), el("App Store", 357, 289),
         el("Plans", 72, 394), el("Santé", 166, 394), el("Réglages", 263, 394),
         el("Q Rechercher", 215, 784)]
    }

    private func blocking(_ apps: [String]) -> PermissionPolicy {
        PermissionPolicy(skipPermissions: false, config: PermissionConfig(blockedApps: apps))
    }

    func testATapOnABlockedAppsIconIsRefused() {
        let refusal = BlockedAppTapGuard.refusal(
            at: CGPoint(x: 263, y: 345), elements: home, windowHeight: height, policy: blocking(["Réglages"]))
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("'Réglages' icon") == true, refusal ?? "")
    }

    func testATapOnTheLabelItselfIsRefused() {
        XCTAssertNotNil(BlockedAppTapGuard.refusal(
            at: CGPoint(x: 263, y: 394), elements: home, windowHeight: height, policy: blocking(["réglages"])))
    }

    func testANeighbouringIconIsAllowed() {
        XCTAssertNil(BlockedAppTapGuard.refusal(
            at: CGPoint(x: 166, y: 345), elements: home, windowHeight: height, policy: blocking(["Réglages"])))
        XCTAssertNil(BlockedAppTapGuard.refusal(
            at: CGPoint(x: 263, y: 240), elements: home, windowHeight: height, policy: blocking(["Réglages"])),
            "the Horloge icon sits above Réglages' reach")
    }

    /// Text that names a blocked app inside an app (a Settings link, a message) is no icon.
    func testTheSameWordOutsideTheHomeScreenIsAllowed() {
        let inApp = [el("Réglages", 263, 394), el("Général", 120, 300)]
        XCTAssertNil(BlockedAppTapGuard.refusal(
            at: CGPoint(x: 263, y: 394), elements: inApp, windowHeight: height, policy: blocking(["Réglages"])))
    }

    func testASpotlightTileOfABlockedAppIsRefused() {
        let spotlight = [el("Meilleur résultat", 86, 107), el("Réglages", 79, 219), el("Réglages - Ouvrir", 156, 874)]
        XCTAssertNotNil(BlockedAppTapGuard.refusal(
            at: CGPoint(x: 79, y: 189), elements: spotlight, windowHeight: height, policy: blocking(["Réglages"])))
    }

    func testNothingIsBlockedWithoutBlockedApps() {
        XCTAssertNil(BlockedAppTapGuard.refusal(
            at: CGPoint(x: 263, y: 345), elements: home, windowHeight: height,
            policy: PermissionPolicy(skipPermissions: false, config: nil)))
    }
}
