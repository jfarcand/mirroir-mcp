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
// ABOUTME: Tests for EnvConfig.readInt and readUInt32 with out-of-range settings values.
// ABOUTME: A hand-edited settings.json must fall back or clamp, never trap the server.

import XCTest
@testable import HelperLib

final class EnvConfigReadNumberTests: XCTestCase {

    private let key = "testNumberKey"

    private func readUInt32(_ value: Any) -> UInt32 {
        EnvConfig.readUInt32(key, default: 7, settings: [key: value], env: [:])
    }

    private func readInt(_ value: Any) -> Int {
        EnvConfig.readInt(key, default: 7, settings: [key: value], env: [:])
    }

    func testUInt32ClampsIntegersAboveRange() {
        XCTAssertEqual(readUInt32(Int.max), UInt32.max)
        XCTAssertEqual(readUInt32(Int(UInt32.max) + 1), UInt32.max)
        XCTAssertEqual(readUInt32(1500), 1500)
    }

    func testUInt32ClampsOrRejectsDoubles() {
        XCTAssertEqual(readUInt32(1e300), UInt32.max)
        XCTAssertEqual(readUInt32(Double.infinity), UInt32.max)
        XCTAssertEqual(readUInt32(Double.nan), 7)
        XCTAssertEqual(readUInt32(12.9), 12)
    }

    func testUInt32NegativeFallsBack() {
        XCTAssertEqual(readUInt32(-1), 7)
        XCTAssertEqual(readUInt32(-1.5), 7)
    }

    func testIntRejectsDoublesOutsideRange() {
        XCTAssertEqual(readInt(1e300), 7)
        XCTAssertEqual(readInt(Double.infinity), 7)
        XCTAssertEqual(readInt(Double.nan), 7)
        XCTAssertEqual(readInt(-3.7), -3)
    }

    func testEnvParsesWhenSettingsAbsent() {
        let envKey = EnvConfig.envVarName(key)
        XCTAssertEqual(EnvConfig.readInt(key, default: 7, settings: [:], env: [envKey: "42"]), 42)
        XCTAssertEqual(EnvConfig.readUInt32(key, default: 7, settings: [:], env: [envKey: "-1"]), 7)
    }
}
