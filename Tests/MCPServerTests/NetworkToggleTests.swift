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
// ABOUTME: Tests for NetworkToggle, the set_network procedure behind the tool and the skill step.
// ABOUTME: The switch is read before and after; it is tapped only when not already in the asked state.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

final class NetworkToggleTests: XCTestCase {

    private var input: StubInput!
    private var describer: StubDescriber!
    private var bridge: StubBridge!

    /// The switch on the row at `switchRowY`, as the reader sees it: `initial`
    /// until a tap lands on the switch, then the other state.
    private var switchRowY = 511.0
    private var initial = SettingsSwitchReader.State.off
    private var flips = true
    private let switchX = 345.0

    override func setUp() {
        super.setUp()
        input = StubInput()
        describer = StubDescriber()
        bridge = StubBridge()
    }

    private func screen(_ rows: [(String, Double)]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: rows.map { TapPoint(text: $0.0, tapX: 120, tapY: $0.1, confidence: 0.95) },
            screenshotBase64: "")
    }

    /// Settings' first page on an iPhone 16 (iOS 27, French), 2026-11-18.
    private var firstPage: ScreenDescriber.DescribeResult {
        screen([("Réglages", 178), ("Mode Avion", 511), ("Wi-Fi", 561), ("Bluetooth", 614),
                ("Réseau cellulaire", 667), ("Q Rechercher", 838)])
    }

    /// The Wi-Fi page: its title and its switch row both read "Wi-Fi".
    private var wifiPage: ScreenDescriber.DescribeResult {
        screen([("Wi-Fi", 290), ("Wi-Fi", 456), ("Assistance connectivité", 785)])
    }

    private var switchTapped: Bool { input.tapCalls.contains { $0.x == switchX } }

    private func toggle(_ mode: String) -> Result<String, NetworkToggle.ToggleError> {
        let (input, switchRowY, initial, flips, switchX) = (input!, switchRowY, initial, flips, switchX)
        let read: NetworkToggle.SwitchRead = { _, rowY, _ in
            guard rowY == switchRowY else { return .init(state: .none, center: nil) }
            let tapped = input.tapCalls.contains { $0.x == switchX }
            let state: SettingsSwitchReader.State = tapped && flips ? (initial == .on ? .off : .on) : initial
            return .init(state: state, center: CGPoint(x: switchX, y: rowY))
        }
        return NetworkToggle.toggle(mode: mode, input: input, describer: describer, menuBridge: bridge,
                                    settleUs: 0, loadUs: 0, read: read)
    }

    private var wentHome: Bool {
        bridge.menuActionCalls.contains { $0.menu == "View" && $0.item == "Home Screen" }
    }

    // MARK: - Airplane Mode, on the first page

    /// carnet#79: _on and _off tapped the same label, so _on could turn it off.
    func testASwitchAlreadyInTheAskedStateIsNotTapped() {
        describer.describeResult = firstPage
        XCTAssertEqual(toggle("airplane_off"), .success("Airplane Mode is already off: nothing was tapped."))
        XCTAssertTrue(input.tapCalls.isEmpty)
        XCTAssertTrue(wentHome)
    }

    func testTheSwitchIsTappedAndReadAgain() throws {
        describer.describeResult = firstPage
        let message = try toggle("airplane_on").get()
        XCTAssertTrue(message.hasPrefix("Turned Airplane Mode on: the switch now reads on."), message)
        XCTAssertTrue(message.contains("cut iPhone Mirroring's connection"), message)
        XCTAssertEqual(input.tapCalls.map(\.x), [switchX], "the switch, not the label")
    }

    func testATapThatDidNotTakeFails() {
        flips = false
        describer.describeResult = firstPage
        guard case .failure(let error) = toggle("airplane_on") else { return XCTFail("passed") }
        XCTAssertTrue(error.message.contains("still reads off"), error.message)
    }

    func testTwoDifferentReadsTapNothing() {
        describer.describeResults = [firstPage, firstPage, screen([("Mode Avion", 520)])]
        guard case .failure(let error) = toggle("airplane_on") else { return XCTFail("passed") }
        XCTAssertTrue(error.message.contains("nothing was tapped"), error.message)
        XCTAssertFalse(switchTapped)
    }

    // MARK: - Wi-Fi and cellular data, on their pages

    func testWiFiIsSetOnItsPageAtTheRowWithASwitch() throws {
        switchRowY = 456
        initial = .on
        describer.describeResults = [firstPage, wifiPage]
        let message = try toggle("wifi_off").get()
        XCTAssertTrue(message.hasPrefix("Turned Wi-Fi off"), message)
        XCTAssertEqual(input.tapCalls.map(\.y), [561, 456], "open the page, then the switch")
    }

    /// iPhone 16, two SIMs: cellular data is a menu ("Principale >"), no switch.
    func testACellularMenuIsRefused() {
        switchRowY = 0
        describer.describeResults = [firstPage, screen([("Réseau cellulaire", 270), ("Données cellulaires", 497)])]
        guard case .failure(let error) = toggle("cellular_off") else { return XCTFail("passed") }
        XCTAssertTrue(error.message.hasPrefix("No cellular data switch was found"), error.message)
        XCTAssertEqual(input.tapCalls.map(\.y), [667], "only the page was opened")
        XCTAssertTrue(wentHome)
    }

    // MARK: - Reaching the first page

    /// Settings reopens on the page it was left on (2026-11-18: the Wi-Fi page).
    func testSettingsReopenedOnASubPageGoesBack() {
        describer.describeResults = [wifiPage, firstPage]
        XCTAssertEqual(toggle("airplane_off"), .success("Airplane Mode is already off: nothing was tapped."))
        XCTAssertEqual(input.tapCalls.count, 1, "one back tap")
    }

    func testARowNotFoundTapsNothing() {
        describer.describeResult = screen([("Général", 300)])
        guard case .failure(let error) = toggle("airplane_on") else { return XCTFail("passed") }
        XCTAssertTrue(error.message.contains("not found in Settings"), error.message)
        XCTAssertFalse(switchTapped)
        XCTAssertTrue(wentHome)
    }

    func testEnglishLabelsAreFound() {
        describer.describeResult = screen([("Airplane Mode", 511), ("Wi-Fi", 561)])
        XCTAssertEqual(toggle("airplane_off"), .success("Airplane Mode is already off: nothing was tapped."))
    }

    func testUnknownModeOpensNothing() {
        guard case .failure(let error) = toggle("bluetooth_off") else { return XCTFail("accepted") }
        XCTAssertTrue(error.message.hasPrefix("Unknown mode: bluetooth_off. Use: airplane_on"), error.message)
        XCTAssertTrue(input.launchAppCalls.isEmpty)
        XCTAssertFalse(wentHome)
    }

    func testEachSettingsNameIsTriedToLaunch() {
        input.launchAppResult = "not installed"
        guard case .failure(let error) = toggle("airplane_on") else { return XCTFail("passed") }
        XCTAssertEqual(input.launchAppCalls, ["Settings", "Réglages"])
        XCTAssertTrue(error.message.hasPrefix("Failed to launch Settings"), error.message)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }
}
