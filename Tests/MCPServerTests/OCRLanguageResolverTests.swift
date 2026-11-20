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
// ABOUTME: Unit tests for OCRLanguageResolver: matching requested languages to Vision's codes.
// ABOUTME: Uses the supported list Vision reports on macOS 26 (accurate level), plus the live list.

import Vision
import XCTest
@testable import mirroir_mcp

final class OCRLanguageResolverTests: XCTestCase {

    /// `VNRecognizeTextRequest.supportedRecognitionLanguages()` at the
    /// accurate level, as reported on macOS 26.5.
    private let supported = [
        "en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR", "zh-Hans", "zh-Hant",
        "yue-Hans", "yue-Hant", "ko-KR", "ja-JP", "ru-RU", "uk-UA", "th-TH", "vi-VT",
        "ar-SA", "ars-SA", "tr-TR", "id-ID", "cs-CZ", "da-DK", "nl-NL", "no-NO",
        "nn-NO", "nb-NO", "ms-MY", "pl-PL", "ro-RO", "sv-SE",
    ]

    func testExactCodeIsKept() {
        XCTAssertEqual(OCRLanguageResolver.match("ja-JP", in: supported), "ja-JP")
    }

    func testBareLanguageMapsToItsListedRegion() {
        XCTAssertEqual(OCRLanguageResolver.match("fr", in: supported), "fr-FR")
        XCTAssertEqual(OCRLanguageResolver.match("ko", in: supported), "ko-KR")
    }

    func testOtherRegionMapsToTheListedOne() {
        XCTAssertEqual(OCRLanguageResolver.match("en-CA", in: supported), "en-US")
        XCTAssertEqual(OCRLanguageResolver.match("fr-CA", in: supported), "fr-FR")
    }

    func testChineseRegionMapsByScript() {
        XCTAssertEqual(OCRLanguageResolver.match("zh-TW", in: supported), "zh-Hant")
        XCTAssertEqual(OCRLanguageResolver.match("zh-CN", in: supported), "zh-Hans")
        XCTAssertEqual(OCRLanguageResolver.match("zh-Hant-HK", in: supported), "zh-Hant")
    }

    func testUnlistedLanguageHasNoMatch() {
        XCTAssertNil(OCRLanguageResolver.match("ga-IE", in: supported))
        XCTAssertNil(OCRLanguageResolver.match("", in: supported))
        XCTAssertNil(OCRLanguageResolver.match("und", in: supported))
    }

    func testResolveKeepsOrderAndDropsDuplicates() {
        let resolved = OCRLanguageResolver.resolve(
            requested: ["en-CA", "fr", "en-US"], supported: supported)
        XCTAssertEqual(resolved, ["en-US", "fr-FR"])
    }

    func testResolveSkipsUnlistedLanguages() {
        let resolved = OCRLanguageResolver.resolve(
            requested: ["ga-IE", "ko-KR"], supported: supported)
        XCTAssertEqual(resolved, ["ko-KR"])
    }

    func testResolveWithNoMatchReadsEnglish() {
        let resolved = OCRLanguageResolver.resolve(requested: ["ga-IE"], supported: supported)
        XCTAssertEqual(resolved, ["en-US"])
    }

    func testUnmatchedListsOnlyUnlistedCodes() {
        let unmatched = OCRLanguageResolver.unmatched(
            requested: ["ga-IE", "fr", "xx"], supported: supported)
        XCTAssertEqual(unmatched, ["ga-IE", "xx"])
    }

    func testDefaultRequestPutsTheMacLanguagesBeforeEnglish() {
        XCTAssertEqual(
            OCRLanguageResolver.defaultRequest(preferred: ["ko-KR", "fr-CA"]),
            ["ko-KR", "fr-CA", "en-US"])
    }

    func testKoreanMacResolvesKoreanThenEnglish() {
        let requested = OCRLanguageResolver.defaultRequest(preferred: ["ko"])
        XCTAssertEqual(
            OCRLanguageResolver.resolve(requested: requested, supported: supported),
            ["ko-KR", "en-US"])
    }

    /// Against the list this machine's Vision reports, so a code Vision renames
    /// shows up here rather than as text OCR silently stops reading.
    func testLiveVisionListResolvesCommonLanguages() throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let live = try request.supportedRecognitionLanguages()
        XCTAssertEqual(
            OCRLanguageResolver.resolve(requested: ["fr-CA", "ja", "zh-TW", "en-GB"], supported: live),
            ["fr-FR", "ja-JP", "zh-Hant", "en-US"])
    }
}
