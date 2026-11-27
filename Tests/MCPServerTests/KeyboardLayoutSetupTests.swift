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
// ABOUTME: Tests that configure saves a layout name typing can find, and that check_health names one it cannot.
// ABOUTME: "Swiss German" (with a space) used to be saved and silently typed with US keys.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class KeyboardLayoutSetupTests: XCTestCase {

    private let installed = [
        LayoutMapper.InstalledLayout(sourceID: "com.apple.keylayout.SwissGerman", name: "Swiss German"),
        LayoutMapper.InstalledLayout(sourceID: "com.apple.keylayout.Canadian-CSA", name: "Canadian – CSA"),
    ]

    func testAnOtherLayoutTypedAsShownIsSavedByItsSourceID() {
        XCTAssertEqual(ConfigureCommand.savedName(forCustomLayout: "Swiss German", installed: installed), "SwissGerman")
        XCTAssertEqual(ConfigureCommand.savedName(forCustomLayout: "Canadian – CSA", installed: installed), "Canadian-CSA")
    }

    func testAnInstalledSourceIDIsSavedAsTyped() {
        XCTAssertEqual(ConfigureCommand.savedName(forCustomLayout: "Canadian-CSA", installed: installed), "Canadian-CSA")
    }

    func testAnUnknownLayoutIsSavedAsTyped() {
        XCTAssertEqual(ConfigureCommand.savedName(forCustomLayout: "Klingon", installed: installed), "Klingon")
    }

    func testEveryListedLayoutIsOneTypingFinds() {
        for layout in ConfigureCommand.layouts {
            XCTAssertNotNil(IPhoneKeyboardLayout.named(layout.name), "\(layout.description) saves '\(layout.name)'")
            XCTAssertEqual(KeyboardLayoutSet.unknownNames([layout.name]), [], layout.name)
        }
    }

    func testTheSpacedNameFromAnEarlierConfigureStillTypes() {
        XCTAssertEqual(KeyboardLayoutSet.unknownNames(["Swiss German", "US"]), [])
    }

    func testAnUnknownNameIsReported() {
        XCTAssertEqual(KeyboardLayoutSet.unknownNames(["Klingon", "Canadian-CSA"]), ["Klingon"])
    }
}
