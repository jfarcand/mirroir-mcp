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
// ABOUTME: Tests for set_network through Control Center: reading a connectivity tile's label and state line,
// ABOUTME: and the gate that sends an iPhone Mirroring without Control Center (or an iPhone before iOS 27) to Settings.

import XCTest
import CoreGraphics
import HelperLib
@testable import mirroir_mcp

final class ControlCenterNetworkTests: XCTestCase {

    private var input: StubInput!
    private var describer: StubDescriber!
    private var bridge: StubBridge!

    override func setUp() {
        super.setUp()
        input = StubInput()
        describer = StubDescriber()
        bridge = StubBridge()
    }

    private func screen(_ rows: [(String, Double, Double)]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: rows.map { TapPoint(text: $0.0, tapX: $0.1, tapY: $0.2, confidence: 0.95) },
            screenshotBase64: "")
    }

    /// Control Center's connectivity page on an iPhone 16 (iOS 27.2.1, French),
    /// window 426x935, 2026-11-23. The network and accessory names are made up.
    private func connectivity(cellular: String = "Principale") -> ScreenDescriber.DescribeResult {
        screen([("•• Opérateur Wi-Fi", 75, 160), ("Mode Avion", 149, 172), ("Non", 123, 190),
                ("Wi-Fi", 85, 343), ("AirDrop", 264, 344), ("Maison", 108, 362),
                ("Contacts uniquement", 301, 362), ("••UI", 80, 444), ("Données", 96, 499),
                ("cellulaires", 101, 517), ("Bluetooth", 272, 517), ("Montre", 286, 535),
                (cellular, 99, 536), ("Partage (connexion)", 179, 606), ("Non", 123, 622),
                ("VPN", 124, 691), ("Non", 122, 709), ("Satellite", 137, 778),
                ("Non disponible", 159, 797)])
    }

    /// Control Center's first page: no connectivity labels, only icons.
    private var mainPage: ScreenDescriber.DescribeResult {
        screen([("Services système ›", 229, 115), ("Concen-", 132, 429), ("tration", 119, 443)])
    }

    private func tile(_ section: SystemPhrases.Section,
                      _ result: ScreenDescriber.DescribeResult) -> ControlCenterNetwork.Tile? {
        ControlCenterNetwork.tile(section, in: result.elements, phrases: .live)
    }

    private func state(_ section: SystemPhrases.Section,
                       _ result: ScreenDescriber.DescribeResult) -> SettingsSwitchReader.State? {
        tile(section, result).map { ControlCenterNetwork.state(of: $0, phrases: .live) }
    }

    // MARK: - Reading a tile

    func testEachTileReadsTheLineUnderItsOwnLabel() {
        XCTAssertEqual(tile(.controlCenterAirplaneTile, connectivity())?.status, "Non")
        XCTAssertEqual(tile(.controlCenterWiFiTile, connectivity())?.status, "Maison",
                       "not AirDrop's line beside it, nor the carrier line in the status bar")
        XCTAssertEqual(tile(.controlCenterCellularTile, connectivity())?.status, "Principale",
                       "not Bluetooth's accessory beside it")
    }

    /// OCR reads "Données cellulaires" as two lines.
    func testALabelSplitOverTwoLinesIsJoinedAndTappedOnItsFirstLine() {
        let cellular = tile(.controlCenterCellularTile, connectivity())
        XCTAssertEqual(cellular?.label.text, "Données")
        XCTAssertEqual(cellular?.label.tapY, 499)
    }

    /// 2026-11-23: cellular data turned off showed "Non" where "Principale" was.
    func testTheOffWordReadsOffAndAnyOtherLineReadsOn() {
        XCTAssertEqual(state(.controlCenterAirplaneTile, connectivity()), .off)
        XCTAssertEqual(state(.controlCenterWiFiTile, connectivity()), .on, "a network name")
        XCTAssertEqual(state(.controlCenterCellularTile, connectivity()), .on, "a SIM line")
        XCTAssertEqual(state(.controlCenterCellularTile, connectivity(cellular: "Non")), .off)
    }

    /// iPhone 16, iOS 27, 2026-11-24: Control Center's Wi-Fi tap drops the
    /// network, keeps the radio on, and says "Non connecté". wifi_off read
    /// that as on and reported the tap had not taken.
    func testAWiFiTileWithNoNetworkReadsOff() {
        let dropped = screen([("Wi-Fi", 72, 291), ("Non connecté", 100, 307)])
        XCTAssertEqual(state(.controlCenterWiFiTile, dropped), .off)
        let english = screen([("Wi-Fi", 72, 291), ("Not Connected", 100, 307)])
        XCTAssertEqual(state(.controlCenterWiFiTile, english), .off)
    }

    /// iPhone 16, iOS 27, 2026-11-24: OCR read the tile's ⌃⌄ menu chevron as
    /// a stray letter after "Non connecté", and wifi_off reported the dropped
    /// network as still on.
    func testTheMenuChevronAfterTheStateLineIsNotPartOfIt() {
        for misread in ["Non connecté s", "Non connecté *", "Non connecté C", "Non connecté •"] {
            let dropped = screen([("Wi-Fi", 71, 330), (misread, 100, 345)])
            XCTAssertEqual(state(.controlCenterWiFiTile, dropped), .off, misread)
        }
        let joined = screen([("Wi-Fi", 71, 330), ("Treberden *", 91, 345)])
        XCTAssertEqual(state(.controlCenterWiFiTile, joined), .on)
        XCTAssertEqual(state(.controlCenterAirplaneTile, connectivity()), .off, "a lone off word stays")
        XCTAssertEqual(ControlCenterNetwork.withoutMenuChevron("Non"), "Non")
    }

    func testALabelWithNoLineUnderItIsUnreadable() {
        let lone = screen([("Wi-Fi", 85, 343)])
        XCTAssertEqual(state(.controlCenterWiFiTile, lone), SettingsSwitchReader.State.none)
    }

    /// 2026-11-23, window 340x749: OCR missed the faint "Non" under "Mode
    /// Avion", and a detector "icon" 10 pt below it was read as the state line,
    /// so `airplane_off` read on and tapped Airplane Mode on.
    func testADetectorIconUnderALabelIsNotItsStateLine() {
        let missedState = screen([("Mode Avion", 119, 167), ("icon", 178, 177),
                                  ("Wi-Fi", 68, 302), ("Maison", 86, 317),
                                  ("Données", 78, 426), ("icon", 204, 421), ("cellulaires", 81, 440)])
        XCTAssertEqual(state(.controlCenterAirplaneTile, missedState), SettingsSwitchReader.State.none)
        XCTAssertEqual(state(.controlCenterCellularTile, missedState), SettingsSwitchReader.State.none,
                       "cellular's own state line was missed too")
        XCTAssertEqual(state(.controlCenterWiFiTile, missedState), .on)
    }

    func testAnUnreadableTileIsNeverTapped() {
        bridge.menuItemResult = true
        describer.describeResult = screen([("Mode Avion", 119, 167), ("icon", 178, 177)])
        guard case .failure(let error) = toggle("airplane_off") else { return XCTFail("passed") }
        XCTAssertTrue(error.message.contains("Nothing was tapped"), error.message)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    /// The connectivity page as the vision describer reported it, 2026-11-23
    /// (iPhone 16, iOS 27.2.1, window 359x790; names made up).
    private var visionConnectivity: ScreenDescriber.DescribeResult {
        screen([("Services système", 186, 101), ("Mode Avion — Non", 179, 195),
                ("Wi-Fi — Maison", 107, 303), ("AirDrop — Contacts uniquement", 251, 303),
                ("Données cellulaires — Principale", 107, 448), ("Bluetooth — Montre", 251, 448),
                ("Connectivité", 333, 456), ("Partage (connexion) — Non", 179, 558)])
    }

    func testAVisionElementHoldsTheLabelAndTheState() {
        XCTAssertEqual(state(.controlCenterAirplaneTile, visionConnectivity), .off)
        XCTAssertEqual(state(.controlCenterWiFiTile, visionConnectivity), .on)
        XCTAssertEqual(state(.controlCenterCellularTile, visionConnectivity), .on)
        XCTAssertEqual(tile(.controlCenterCellularTile, visionConnectivity)?.label.tapY, 448,
                       "tapped where the vision model placed the tile")
    }

    func testAVisionElementWithNoStateIsUnreadable() {
        let noState = screen([("Mode Avion — ", 179, 195)])
        XCTAssertEqual(state(.controlCenterAirplaneTile, noState), SettingsSwitchReader.State.none)
    }

    /// Control Center's first page as the vision describer reported it,
    /// 2026-11-23: every icon named, no state.
    private var visionMainPage: ScreenDescriber.DescribeResult {
        screen([("Services système", 186, 101), ("Mode avion", 77, 200), ("AirDrop", 137, 200),
                ("Données cellulaires", 124, 234), ("Bluetooth", 150, 248), ("Wi-Fi", 77, 260),
                ("Connectivité", 333, 456)])
    }

    func testControlCenterFirstPageIsNotTheConnectivityPage() {
        XCTAssertFalse(ControlCenterNetwork.isConnectivityPage(visionMainPage.elements, phrases: .live),
                       "it names Mode avion, with no state")
        XCTAssertTrue(ControlCenterNetwork.isConnectivityPage(visionConnectivity.elements, phrases: .live))
    }

    private func measured(_ rows: [(String, Double, Double, Double)]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: rows.map { TapPoint(text: $0.0, tapX: $0.1, tapY: $0.2, confidence: 0.95, width: $0.3) },
            screenshotBase64: "")
    }

    /// The connectivity page as OCR read it, with each line's width: iPhone 16,
    /// iOS 27.2.1, window 359x790, 2026-11-24 (the network and accessory names
    /// are made up; the icon is placed from the label, not from them). The icons were measured on the same capture at
    /// Airplane Mode (71, 157), Wi-Fi (71, 229) and cellular data (71, 374).
    private func ocrConnectivity(cellular: String = "Principale",
                                 wifi: String = "Maison") -> ScreenDescriber.DescribeResult {
        measured([("Mode Avion", 126, 150, 74), ("Non", 104, 165, 30),
                  ("Wi-Fi", 72, 294, 32), ("AirDrop", 223, 294, 46), (wifi, 77, 309, 42),
                  ("Contacts uniquement", 255, 310, 108),
                  ("Données", 82, 424, 52), ("cellulaires", 86, 440, 60), ("Bluetooth", 229, 440, 56),
                  (cellular, 84, 455, 56), ("Montre", 223, 454, 46),
                  ("Partage (connexion)", 153, 514, 118), ("Non", 104, 528, 30)])
    }

    private func icon(_ section: SystemPhrases.Section, _ result: ScreenDescriber.DescribeResult,
                      width: Double) throws -> CGPoint {
        let found = try XCTUnwrap(tile(section, result))
        return try XCTUnwrap(ControlCenterNetwork.iconPoint(
            of: found, shape: ControlCenterNetwork.shape(of: section), windowWidth: width))
    }

    func testTheIconIsPlacedFromTheTileText() throws {
        let page = ocrConnectivity()
        let cellular = try icon(.controlCenterCellularTile, page, width: 359)
        XCTAssertEqual(cellular.x, 71, accuracy: 2)
        XCTAssertEqual(cellular.y, 374, accuracy: 2)
        let wifi = try icon(.controlCenterWiFiTile, page, width: 359)
        XCTAssertEqual(wifi.x, 71, accuracy: 2)
        XCTAssertEqual(wifi.y, 229, accuracy: 2)
        let airplane = try icon(.controlCenterAirplaneTile, page, width: 359)
        XCTAssertEqual(airplane.x, 71, accuracy: 2, "left of its text: a full-width tile")
        XCTAssertEqual(airplane.y, 157, accuracy: 2)
    }

    /// The same page with the window zoomed out to 319x703, 2026-11-24: the
    /// cellular icon measured at (63.5, 335), and a tap there toggled it.
    func testTheIconOffsetsScaleWithTheWindow() throws {
        let zoomedOut = measured([("Données", 74, 379, 48), ("cellulaires", 77, 392, 54),
                                  ("Principale", 76, 406, 50)])
        let cellular = try icon(.controlCenterCellularTile, zoomedOut, width: 319)
        XCTAssertEqual(cellular.x, 63.5, accuracy: 2)
        XCTAssertEqual(cellular.y, 335, accuracy: 2)
    }

    /// A vision model reports a tile as one element, with no width and no
    /// separate state line: it cannot place the icon.
    func testAVisionTileCannotPlaceTheIcon() throws {
        let cellular = try XCTUnwrap(tile(.controlCenterCellularTile, visionConnectivity))
        XCTAssertNil(ControlCenterNetwork.iconPoint(of: cellular, shape: .square, windowWidth: 359))
    }

    /// Read the state on the connectivity page, tap the icon OCR places there,
    /// and read again: no paging after the page is found.
    func testTheToggleTapsTheIconAndReadsAgain() {
        bridge.menuItemResult = true
        bridge.windowInfo = WindowInfo(windowID: 1, position: .zero,
                                       size: CGSize(width: 359, height: 790), pid: 1)
        let off = ocrConnectivity(cellular: "Non")
        describer.describeResults = [ocrConnectivity(), ocrConnectivity(), ocrConnectivity(),  // open, read twice
                                     ocrConnectivity(),                                       // place the icon
                                     off]                                                     // read again
        XCTAssertEqual(toggle("cellular_off"), .success("Turned cellular data off: the tile now reads off."))
        XCTAssertEqual(input.tapCalls.count, 1)
        XCTAssertEqual(input.tapCalls.first?.x ?? 0, 71, accuracy: 2)
        XCTAssertEqual(input.tapCalls.first?.y ?? 0, 374, accuracy: 2)
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }

    /// iPhone 16, iOS 27, 2026-11-24: read 0.85 s after the tap, the Wi-Fi tile
    /// still showed its network while disconnecting, and wifi_off reported a
    /// tap that had taken as one that had not. The tile is read again until it
    /// changes.
    func testATileIsReadAgainUntilItChanges() {
        bridge.menuItemResult = true
        bridge.windowInfo = WindowInfo(windowID: 1, position: .zero,
                                       size: CGSize(width: 359, height: 790), pid: 1)
        describer.describeResults = [ocrConnectivity(), ocrConnectivity(), ocrConnectivity(),  // open, read twice
                                     ocrConnectivity(),                                       // place the icon
                                     ocrConnectivity(),                                       // still the network
                                     ocrConnectivity(wifi: "Non connecté")]                   // dropped
        let result = NetworkToggle.toggle(mode: "wifi_off", input: input, describer: describer,
                                          menuBridge: bridge, settleUs: 1, changeTimeoutUs: 3, loadUs: 0)
        guard case .success(let message) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(message.hasPrefix("Turned Wi-Fi off: the tile now reads off."), message)
        XCTAssertEqual(input.tapCalls.count, 1)
        XCTAssertEqual(describer.describeCallCount, 6, "no read after the tile changed")
    }

    /// A tile that never changes is read once per settle until the deadline,
    /// then reported, and tapped only once.
    func testATileThatNeverChangesIsReadUntilTheDeadline() {
        bridge.menuItemResult = true
        describer.describeResult = ocrConnectivity()
        let result = NetworkToggle.toggle(mode: "cellular_off", input: input, describer: describer,
                                          menuBridge: bridge, settleUs: 1, changeTimeoutUs: 3, loadUs: 0)
        guard case .failure(let error) = result else { return XCTFail("passed") }
        XCTAssertTrue(error.message.contains("still reads on"), error.message)
        XCTAssertEqual(input.tapCalls.count, 1)
        XCTAssertEqual(describer.describeCallCount, 4 + 3, "open, two reads, the icon, then three reads")
    }

    func testATileTapThatDidNotTakeFails() {
        bridge.menuItemResult = true
        describer.describeResult = ocrConnectivity()
        guard case .failure(let error) = toggle("cellular_off") else { return XCTFail("passed") }
        XCTAssertTrue(error.message.contains("Tapped the cellular data tile, but it still reads on"),
                      error.message)
    }

    /// A vision model reads the state; when OCR then misses the tile, its icon
    /// has no place and nothing is tapped.
    func testWhenOCRMissesTheTileNothingIsTapped() {
        bridge.menuItemResult = true
        let tileReader = StubDescriber()
        tileReader.describeResult = visionConnectivity
        describer.describeResult = screen([("Mode Avion", 126, 150), ("Non", 104, 165)])
        let result = NetworkToggle.toggle(
            mode: "cellular_off", input: input, describer: describer,
            controlCenterDescriber: tileReader, menuBridge: bridge, settleUs: 0, changeTimeoutUs: 0,
            loadUs: 0)
        guard case .failure(let error) = result else { return XCTFail("passed") }
        XCTAssertTrue(error.message.contains("nothing was tapped"), error.message)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    func testEnglishLabelsAreRead() {
        let english = screen([("Airplane Mode", 149, 172), ("Off", 123, 190),
                              ("Cellular", 96, 499), ("Data", 101, 517), ("On", 99, 536)])
        XCTAssertEqual(state(.controlCenterAirplaneTile, english), .off)
        XCTAssertEqual(state(.controlCenterCellularTile, english), .on)
    }

    // MARK: - set_network through Control Center

    private func toggle(_ mode: String, settingsRefusal: String? = nil)
        -> Result<String, NetworkToggle.ToggleError> {
        NetworkToggle.toggle(mode: mode, input: input, describer: describer, menuBridge: bridge,
                             settleUs: 0, changeTimeoutUs: 0, loadUs: 0,
                             settingsRefusal: { settingsRefusal })
    }

    private var wentHome: Bool {
        bridge.menuActionCalls.contains { $0.menu == "View" && $0.item == "Home Screen" }
    }

    func testATileAlreadyInTheAskedStateIsNotTappedAndSettingsIsNotOpened() {
        bridge.menuItemResult = true
        describer.describeResult = connectivity()
        XCTAssertEqual(toggle("airplane_off", settingsRefusal: "Settings is blocked"),
                       .success("Airplane Mode is already off: nothing was tapped."),
                       "Control Center is not the Settings app the policy blocks")
        XCTAssertEqual(bridge.menuItemCalls, [ControlCenterNetwork.commandKey])
        XCTAssertTrue(input.launchAppCalls.isEmpty)
        XCTAssertTrue(input.tapCalls.isEmpty)
        XCTAssertTrue(wentHome)
    }

    func testControlCenterIsPagedToItsConnectivityTiles() {
        bridge.menuItemResult = true
        describer.describeResults = [mainPage, connectivity()]
        XCTAssertEqual(toggle("airplane_off"), .success("Airplane Mode is already off: nothing was tapped."))
        XCTAssertEqual(input.swipeCalls.count, 1)
    }

    /// 2026-11-23: a 1900 pt/s swipe was posted as a drag and never paged.
    func testThePageSwipeIsAFlickInEveryWindowSize() throws {
        bridge.menuItemResult = true
        for height in [701.0, 749.0, 935.0] {
            bridge.windowInfo = WindowInfo(windowID: 1, position: .zero,
                                           size: CGSize(width: height * 0.45, height: height), pid: 1)
            input.swipeCalls = []
            describer = StubDescriber()
            describer.describeResults = [mainPage, connectivity()]
            _ = toggle("airplane_off")
            let swipe = try XCTUnwrap(input.swipeCalls.first)
            let speed = (swipe.fromY - swipe.toY) / (Double(swipe.durationMs) / 1000)
            XCTAssertGreaterThanOrEqual(speed, SwipeGestureProfile.flickVelocity, "height \(height)")
        }
    }

    func testControlCenterWithoutConnectivityTilesTapsNothing() {
        bridge.menuItemResult = true
        describer.describeResult = mainPage
        guard case .failure(let error) = toggle("wifi_off") else { return XCTFail("passed") }
        XCTAssertTrue(error.message.contains("were not found on any page"), error.message)
        XCTAssertEqual(input.swipeCalls.count, 1, "a page that does not move ends the search")
        XCTAssertTrue(input.tapCalls.isEmpty)
        XCTAssertTrue(input.launchAppCalls.isEmpty, "Settings is not the answer to an unread page")
    }

    // MARK: - The gate: Settings when Mirroring gives no Control Center

    /// The XR (iOS 18.7.12) on macOS 27.2.1, 2026-11-23: Mirroring showed
    /// "Update Required: To use Control Centre with iPhone Mirroring, update to
    /// iOS 27 or later" and paused the session.
    func testAnIPhoneMirroringRefusesGoesThroughSettings() {
        bridge.menuItemResult = true
        bridge.stateAfterMenuItem = .paused
        describer.describeResult = screen([("Réglages", 120, 178), ("Mode Avion", 120, 511)])
        _ = toggle("airplane_off")
        XCTAssertEqual(bridge.menuItemCalls, [ControlCenterNetwork.commandKey])
        XCTAssertEqual(input.launchAppCalls.first, "Settings")
    }

    /// macOS 26: iPhone Mirroring has no Control Centre command, and nothing is sent.
    func testNoControlCentreCommandGoesThroughSettingsAndItsPolicy() {
        guard case .failure(let error) = toggle("airplane_off", settingsRefusal: "Settings is blocked")
        else { return XCTFail("passed") }
        XCTAssertEqual(error.message, "Settings is blocked")
        XCTAssertTrue(input.launchAppCalls.isEmpty)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }
}
