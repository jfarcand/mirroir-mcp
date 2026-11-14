// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for NetworkToggle, the set_network procedure behind the tool and the skill step.
// ABOUTME: Covers mode validation, the row labels from system-phrases.md, the tap, and the return home.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class NetworkToggleTests: XCTestCase {

    private var input: StubInput!
    private var describer: StubDescriber!
    private var bridge: StubBridge!

    override func setUp() {
        super.setUp()
        input = StubInput()
        describer = StubDescriber()
        bridge = StubBridge()
    }

    private func settings(_ rows: [(String, Double)]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: rows.map { TapPoint(text: $0.0, tapX: 120, tapY: $0.1, confidence: 0.95) },
            screenshotBase64: "dGVzdA==")
    }

    private func toggle(_ mode: String, phrases: SystemPhrases = .live) -> Result<String, NetworkToggle.ToggleError> {
        NetworkToggle.toggle(mode: mode, input: input, describer: describer, menuBridge: bridge,
                             settleUs: 0, loadUs: 0, phrases: phrases)
    }

    private var wentHome: Bool {
        bridge.menuActionCalls.contains { $0.menu == "View" && $0.item == "Home Screen" }
    }

    func testTapsTheModesRowThenGoesHome() {
        describer.describeResult = settings([("Airplane Mode", 200), ("Wi-Fi", 260), ("Cellular", 320)])

        XCTAssertEqual(toggle("wifi_off"), .success("Toggled wifi_off"))
        XCTAssertEqual(input.launchAppCalls, ["Settings"])
        XCTAssertEqual(input.tapCalls.map(\.y), [260])
        XCTAssertTrue(wentHome)
    }

    func testEachModeTapsItsOwnRow() {
        let rows: [(String, Double)] = [("Airplane Mode", 200), ("Wi-Fi", 260), ("Cellular", 320)]
        let expected: [String: Double] = [
            "airplane_on": 200, "airplane_off": 200, "wifi_on": 260, "wifi_off": 260,
            "cellular_on": 320, "cellular_off": 320,
        ]
        XCTAssertEqual(Set(expected.keys), Set(NetworkToggle.Mode.names))
        for (mode, rowY) in expected {
            input = StubInput()
            describer.describeResult = settings(rows)
            XCTAssertEqual(toggle(mode), .success("Toggled \(mode)"), mode)
            XCTAssertEqual(input.tapCalls.map(\.y), [rowY], mode)
        }
    }

    func testUnknownModeOpensNothing() {
        guard case .failure(let error) = toggle("bluetooth_off") else { return XCTFail("accepted") }
        XCTAssertTrue(error.message.hasPrefix("Unknown mode: bluetooth_off. Use: airplane_on"), error.message)
        XCTAssertTrue(input.launchAppCalls.isEmpty)
        XCTAssertFalse(wentHome)
    }

    func testRowLabelsComeFromThePhrasesFile() {
        let french = SystemPhrases.parse(content: "## Settings Wi-Fi Row\n\n- wi-fi\n- réseau sans fil\n")
        describer.describeResult = settings([("Mode Avion", 200), ("Réseau sans fil", 260)])

        XCTAssertEqual(toggle("wifi_on", phrases: french), .success("Toggled wifi_on"))
        XCTAssertEqual(input.tapCalls.map(\.y), [260])
    }

    func testShippedPhrasesNameEveryRow() {
        for mode in NetworkToggle.Mode.allCases {
            XCTAssertFalse(SystemPhrases.live.phrases(mode.rowSection).isEmpty, mode.rawValue)
        }
    }

    func testMissingRowFailsWithoutTappingAndGoesHome() {
        describer.describeResult = settings([("General", 200)])

        guard case .failure(let error) = toggle("cellular_on") else { return XCTFail("toggled") }
        XCTAssertTrue(error.message.hasPrefix("\"cellular\" not found in Settings"), error.message)
        XCTAssertTrue(input.tapCalls.isEmpty)
        XCTAssertTrue(wentHome)
    }

    func testUnreadableScreenFailsAndGoesHome() {
        describer.describeResult = nil

        XCTAssertEqual(toggle("airplane_on"),
                       .failure(NetworkToggle.ToggleError("Failed to capture Settings screen")))
        XCTAssertTrue(wentHome)
    }

    func testFailedLaunchStopsBeforeReadingTheScreen() {
        input.launchAppResult = "Spotlight did not open"

        XCTAssertEqual(toggle("airplane_on"),
                       .failure(NetworkToggle.ToggleError("Failed to launch Settings: Spotlight did not open")))
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    func testFailedTapIsReportedAndGoesHome() {
        describer.describeResult = settings([("Airplane Mode", 200)])
        input.tapResult = "tap dropped"

        XCTAssertEqual(toggle("airplane_off"),
                       .failure(NetworkToggle.ToggleError("Failed to tap airplane: tap dropped")))
        XCTAssertTrue(wentHome)
    }
}
