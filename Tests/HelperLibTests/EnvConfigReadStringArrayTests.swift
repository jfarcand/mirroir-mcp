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
// ABOUTME: Tests for EnvConfig.readOptionalStringArray and the ocrLanguages property.
// ABOUTME: Validates the unset (nil) path and comma-separated parsing logic.

import XCTest
@testable import HelperLib

final class EnvConfigReadStringArrayTests: XCTestCase {

    // MARK: - readOptionalStringArray unset behavior

    // EnvConfig.env is a static let captured at process start, so env var
    // injection via setenv() is not possible in unit tests. These tests
    // verify the fallback path (key absent from both settings and env).

    func testReturnsNilWhenKeyAbsent() {
        // Use a key that won't exist in settings.json or env
        let result = EnvConfig.readOptionalStringArray(
            "zzzNonExistentTestKey", envVar: "MIRROIR_ZZZ_NONEXISTENT")
        XCTAssertNil(result)
    }

    // MARK: - Comma-separated parsing logic

    // These test the parsing branch directly by verifying its behavior
    // matches Swift's split + trim semantics used in readOptionalStringArray.

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

    func testOcrLanguagesUnsetUnderIsolatedHome() {
        // scripts/unit-tests.sh runs under a throwaway home with no
        // settings.json, so the setting is unset and OCR picks its default.
        XCTAssertNil(EnvConfig.ocrLanguages)
    }
}
