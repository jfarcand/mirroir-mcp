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
// ABOUTME: Maps requested OCR languages (settings or the Mac's preferred languages) onto Vision's codes.
// ABOUTME: Vision ignores a code it does not list (e.g. "fr"), so each request is matched to a listed one.

import Foundation

/// Picks the `recognitionLanguages` for a Vision text request.
///
/// `VNRecognizeTextRequest` accepts any string and silently ignores a code it
/// does not list: `"fr"` or `"en-CA"` reads as if it were never set. Each
/// requested code is therefore matched to a supported one, exactly first, then
/// by language and script (`"fr"` → `"fr-FR"`, `"zh-TW"` → `"zh-Hant"`).
enum OCRLanguageResolver {

    /// The code Vision falls back to, and the language of most iOS chrome
    /// (app names, system labels) whatever the device language.
    static let english = "en-US"

    /// The languages to request when `ocrLanguages` is not configured: the
    /// Mac's preferred languages, then English. The phone mirrored on this Mac
    /// usually shares its owner's languages, and a non-Latin script is read
    /// only when its language is requested.
    static func defaultRequest(preferred: [String]) -> [String] {
        preferred + [english]
    }

    /// Maps `requested` onto `supported`, keeping order and dropping
    /// duplicates. Returns `[english]` when nothing matches, which is what
    /// Vision would read with no usable code.
    static func resolve(requested: [String], supported: [String]) -> [String] {
        var resolved: [String] = []
        for code in requested {
            guard let match = match(code, in: supported), !resolved.contains(match) else { continue }
            resolved.append(match)
        }
        return resolved.isEmpty ? [english] : resolved
    }

    /// The codes in `requested` with no supported match, for logging.
    static func unmatched(requested: [String], supported: [String]) -> [String] {
        requested.filter { match($0, in: supported) == nil }
    }

    /// The supported code for `code`: an exact match, else the first one with
    /// the same language and script once both are expanded to their likely
    /// form (`"en-CA"` and `"en-US"` are both `en-Latn`).
    static func match(_ code: String, in supported: [String]) -> String? {
        if supported.contains(code) { return code }
        let wanted = languageAndScript(code)
        guard wanted.language != nil else { return nil }
        return supported.first { languageAndScript($0) == wanted }
    }

    private static func languageAndScript(_ code: String) -> LanguageAndScript {
        let maximal = Locale.Language(identifier: code).maximalIdentifier
        let language = Locale.Language(identifier: maximal)
        return LanguageAndScript(
            language: language.languageCode?.identifier,
            script: language.script?.identifier)
    }

    private struct LanguageAndScript: Equatable {
        let language: String?
        let script: String?
    }
}
