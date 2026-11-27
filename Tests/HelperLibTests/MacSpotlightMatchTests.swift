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
// ABOUTME: Tests which Mac Spotlight rows are the iPhone app launch_app may click, and how the Spotlight shortcut is read.
// ABOUTME: Rows are as macOS 27 showed them on 2026-11-27: "Waze.app — From iPhone", and a Chrome web app "Strava.app".

import XCTest
@testable import HelperLib

final class MacSpotlightMatchTests: XCTestCase {

    func testTheFromIPhoneRowOfTheNamedAppMatches() {
        XCTAssertTrue(MacSpotlightMatch.isIPhoneApp(rowTexts: ["Waze.app — From iPhone"], named: "Waze"))
    }

    func testFormattingMarksAndCaseAreIgnored() {
        let isolated = "\u{2068}Waze.app\u{2069} — \u{2068}\u{2060}From iPhone\u{2069}"
        XCTAssertTrue(MacSpotlightMatch.isIPhoneApp(rowTexts: [isolated], named: "waze"))
    }

    func testALocalizedSuffixStillNamesTheIPhone() {
        XCTAssertTrue(MacSpotlightMatch.isIPhoneApp(rowTexts: ["Waze.app — De l’iPhone"], named: "Waze"))
    }

    /// The Mac's own Strava (a Chrome web app) shadows the iPhone app's row:
    /// clicking it opened Chrome, not Strava on the iPhone.
    func testAMacAppOfTheSameNameIsNotTaken() {
        XCTAssertFalse(MacSpotlightMatch.isIPhoneApp(rowTexts: ["Strava.app"], named: "Strava"))
    }

    func testTheNameMustMatchWhole() {
        XCTAssertFalse(MacSpotlightMatch.isIPhoneApp(rowTexts: ["Google Maps.app — From iPhone"], named: "Maps"))
        XCTAssertFalse(MacSpotlightMatch.isIPhoneApp(rowTexts: ["Waze.app — From iPhone"], named: "Waz"))
    }

    /// The field's own hint reads "<name>.app — Open"; it is not a result row.
    func testARowWithoutTheIPhoneIsNotTaken() {
        XCTAssertFalse(MacSpotlightMatch.isIPhoneApp(rowTexts: ["Waze.app — Open"], named: "Waze"))
    }

    func testAnUnchangedShortcutIsCommandSpace() {
        XCTAssertEqual(SpotlightHotkey.from(symbolicHotKeys: nil), .commandSpace)
        XCTAssertEqual(SpotlightHotkey.from(symbolicHotKeys: ["60": ["enabled": 1]]), .commandSpace)
    }

    /// As `defaults read com.apple.symbolichotkeys` showed it on the test Mac.
    func testTheConfiguredShortcutIsRead() {
        let entry: [String: Any] = ["enabled": 1, "value": ["parameters": [32, 49, 1_048_576], "type": "standard"]]
        XCTAssertEqual(SpotlightHotkey.from(symbolicHotKeys: ["64": entry]), .commandSpace)
        let optionSpace: [String: Any] = ["enabled": 1, "value": ["parameters": [32, 49, 524_288]]]
        XCTAssertEqual(SpotlightHotkey.from(symbolicHotKeys: ["64": optionSpace]),
                       SpotlightHotkey(keyCode: 49, modifierFlags: 524_288))
    }

    /// A shortcut turned off means nothing is pressed: another launcher may own Command-Space.
    func testATurnedOffShortcutIsNil() {
        XCTAssertNil(SpotlightHotkey.from(symbolicHotKeys: ["64": ["enabled": 0]]))
        XCTAssertNil(SpotlightHotkey.from(symbolicHotKeys: ["64": ["enabled": false]]))
    }
}
