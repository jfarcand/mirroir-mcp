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
// ABOUTME: Tests the keyboardLayout setting reader: one name, a list for phones that take turns, or the env list.
// ABOUTME: An empty name or no setting reads as US QWERTY, and a repeated name counts once.

import XCTest
@testable import HelperLib

final class KeyboardLayoutNamesTests: XCTestCase {

    func testOneNameIsOneLayout() {
        XCTAssertEqual(EnvConfig.layoutNames(setting: "Canadian-CSA", env: nil), ["Canadian-CSA"])
    }

    func testAListNamesALayoutPerPhone() {
        XCTAssertEqual(EnvConfig.layoutNames(setting: ["Canadian-CSA", "US"], env: nil), ["Canadian-CSA", "US"])
    }

    func testEmptyOrMissingIsUS() {
        XCTAssertEqual(EnvConfig.layoutNames(setting: "", env: nil), ["US"])
        XCTAssertEqual(EnvConfig.layoutNames(setting: nil, env: nil), ["US"])
        XCTAssertEqual(EnvConfig.layoutNames(setting: ["Canadian-CSA", ""], env: nil), ["Canadian-CSA", "US"])
    }

    func testTheEnvironmentTakesACommaList() {
        XCTAssertEqual(EnvConfig.layoutNames(setting: nil, env: "Canadian-CSA, US"), ["Canadian-CSA", "US"])
    }

    func testTheSettingWinsOverTheEnvironment() {
        XCTAssertEqual(EnvConfig.layoutNames(setting: "German", env: "US"), ["German"])
    }

    func testARepeatedNameCountsOnce() {
        XCTAssertEqual(EnvConfig.layoutNames(setting: ["US", "US", "Canadian-CSA"], env: nil), ["US", "Canadian-CSA"])
    }
}
