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
// ABOUTME: Tests WindowInputPolicy: window records only on measured macOS versions, and the windowInput setting forcing either path.
// ABOUTME: Also checks the doctor line that reports the chosen path.

import XCTest
@testable import mirroir_mcp

final class WindowInputPolicyTests: XCTestCase {

    private let measured = WindowInputPolicy.lastMeasuredMacOSMajor

    func testAutoUsesWindowRecordsOnMeasuredMacOS() {
        for major in [15, measured] {
            let decision = WindowInputPolicy.decide(setting: "auto", macOSMajor: major)
            XCTAssertTrue(decision.usesWindow, "macOS \(major)")
            XCTAssertEqual(decision.reason, "measured on macOS \(major)")
        }
    }

    /// jfarcand/mirroir-mcp#84: macOS 27.3 accepted the records and dropped
    /// them, so a macOS past the measured ones gets HID input.
    func testAutoUsesHIDOnAnUnmeasuredMacOS() {
        let decision = WindowInputPolicy.decide(setting: "auto", macOSMajor: measured + 1)
        XCTAssertFalse(decision.usesWindow)
        XCTAssertTrue(decision.reason.contains("not measured on macOS \(measured + 1)"), decision.reason)
        XCTAssertTrue(decision.reason.contains("set windowInput to on"), decision.reason)
    }

    func testTheSettingForcesEitherPath() {
        XCTAssertTrue(WindowInputPolicy.decide(setting: "on", macOSMajor: measured + 1).usesWindow)
        XCTAssertTrue(WindowInputPolicy.decide(setting: "ON", macOSMajor: measured + 1).usesWindow)
        XCTAssertFalse(WindowInputPolicy.decide(setting: "off", macOSMajor: measured).usesWindow)
    }

    func testAnUnknownSettingBehavesLikeAutoAndSaysSo() {
        let decision = WindowInputPolicy.decide(setting: "hid", macOSMajor: measured)
        XCTAssertTrue(decision.usesWindow)
        XCTAssertTrue(decision.reason.hasPrefix("windowInput \"hid\" is not auto, on or off"),
                      decision.reason)
        XCTAssertFalse(WindowInputPolicy.decide(setting: "", macOSMajor: measured + 1).usesWindow)
    }

    func testDoctorReportsThePath() {
        let hid = DoctorCommand.checkInputPath(
            WindowInputPolicy.decide(setting: "off", macOSMajor: measured))
        XCTAssertEqual(hid.status, .passed)
        XCTAssertEqual(hid.detail,
                       "HID input (iPhone Mirroring comes to the front for each action): windowInput is off")
        let window = DoctorCommand.checkInputPath(
            WindowInputPolicy.decide(setting: "auto", macOSMajor: measured))
        XCTAssertTrue(window.detail.hasPrefix("window records"), window.detail)
    }
}
