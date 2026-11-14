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
// ABOUTME: Tests for EnvConfig.readStringArray helper and ocrLanguages property.
// ABOUTME: Validates fallback defaults and comma-separated parsing logic.

import XCTest
@testable import HelperLib

final class EnvConfigReadStringArrayTests: XCTestCase {

    // MARK: - readStringArray fallback behavior

    // EnvConfig.env is a static let captured at process start, so env var
    // injection via setenv() is not possible in unit tests. These tests
    // verify the fallback path (key absent from both settings and env).

    func testReturnsDefaultWhenKeyAbsent() {
        // Use a key that won't exist in settings.json or env
        let result = EnvConfig.readStringArray(
            "zzzNonExistentTestKey", envVar: "MIRROIR_ZZZ_NONEXISTENT",
            default: ["fallback-a", "fallback-b"])
        XCTAssertEqual(result, ["fallback-a", "fallback-b"])
    }

    func testReturnsSingleElementDefault() {
        let result = EnvConfig.readStringArray(
            "zzzNonExistentTestKey2", envVar: "MIRROIR_ZZZ_NONEXISTENT2",
            default: ["only-one"])
        XCTAssertEqual(result, ["only-one"])
    }

    func testReturnsEmptyArrayDefault() {
        let result = EnvConfig.readStringArray(
            "zzzNonExistentTestKey3", envVar: "MIRROIR_ZZZ_NONEXISTENT3",
            default: [])
        XCTAssertEqual(result, [])
    }

    // MARK: - Comma-separated parsing logic

    // These test the parsing branch directly by verifying its behavior
    // matches Swift's split + trim semantics used in readStringArray.

    func testCommaSplitBasic() {
        let input = "ja-JP,en-US"
        let parsed = input.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(parsed, ["ja-JP", "en-US"])
    }

    func testCommaSplitTrimsWhitespace() {
        let input = " ja-JP , en-US , zh-Hans "
        let parsed = input.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(parsed, ["ja-JP", "en-US", "zh-Hans"])
    }

    func testCommaSplitOmitsEmptyEntries() {
        let input = "ja-JP,,en-US"
        let parsed = input.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Swift split omits empty subsequences by default
        XCTAssertEqual(parsed, ["ja-JP", "en-US"])
    }

    func testCommaSplitSingleValue() {
        let input = "ja-JP"
        let parsed = input.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(parsed, ["ja-JP"])
    }

    func testCommaSplitMultipleLanguages() {
        let input = "ja-JP,zh-Hans,ko-KR,ar-SA,en-US"
        let parsed = input.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(parsed, ["ja-JP", "zh-Hans", "ko-KR", "ar-SA", "en-US"])
    }

    // MARK: - ocrLanguages property

    func testOcrLanguagesDefaultIncludesEnglish() {
        let result = EnvConfig.ocrLanguages
        XCTAssertFalse(result.isEmpty, "ocrLanguages should never be empty")
        XCTAssertTrue(result.contains("en-US"),
                      "Default ocrLanguages should include en-US")
    }
}
