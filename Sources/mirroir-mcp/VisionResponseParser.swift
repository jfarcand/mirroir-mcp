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
// ABOUTME: Parses AI vision model responses into TapPoint arrays for screen description.
// ABOUTME: Handles JSON extraction from markdown-fenced responses and coordinate scaling.

import Foundation
import HelperLib

/// Parses AI vision model responses into structured screen elements.
/// Normalizes vision-specific indicator descriptions (e.g. "chevron") into
/// OCR-compatible characters (e.g. ">") using mappings from vision-indicators.md.
enum VisionResponseParser {

    /// Lazily loaded vision indicator mappings from component skills.
    private static let indicators: [ComponentLoader.VisionIndicator] = {
        ComponentLoader.loadVisionIndicators()
    }()

    /// A single element detected by the vision model.
    /// Accepts multiple JSON formats: flat x/y or nested center.x/center.y,
    /// and label/text/name for the display text.
    struct VisionElement: Decodable {
        let label: String?
        let text: String?
        let x: Double
        let y: Double
        let type: String?

        /// Resolved text label, preferring `label` over `text`.
        var resolvedText: String {
            label ?? text ?? ""
        }

        private enum CodingKeys: String, CodingKey {
            case label, text, name, x, y, type, kind, center
        }

        private struct CenterCoord: Decodable {
            let x: Double
            let y: Double
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            self.label = try container.decodeIfPresent(String.self, forKey: .label)
                ?? container.decodeIfPresent(String.self, forKey: .name)
            self.text = try container.decodeIfPresent(String.self, forKey: .text)
            self.type = try container.decodeIfPresent(String.self, forKey: .type)
                ?? container.decodeIfPresent(String.self, forKey: .kind)

            if let flatX = try? container.decode(Double.self, forKey: .x),
               let flatY = try? container.decode(Double.self, forKey: .y) {
                self.x = flatX
                self.y = flatY
            } else if let center = try? container.decode(CenterCoord.self, forKey: .center) {
                self.x = center.x
                self.y = center.y
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .x, in: container,
                    debugDescription: "No x/y or center coordinates found")
            }
        }
    }

    /// Parse a vision model response into TapPoints with scaled coordinates.
    ///
    /// - Parameters:
    ///   - responseText: Raw text from the vision model (may contain markdown fences).
    ///   - scaleX: Multiplier to convert vision X coords to window points.
    ///   - scaleY: Multiplier to convert vision Y coords to window points.
    /// - Returns: Array of TapPoints in window-point space, plus derived navigation hints.
    static func parse(
        responseText: String, scaleX: Double, scaleY: Double
    ) -> (elements: [TapPoint], hints: [String]) {
        // Warn if the response appears truncated (no closing bracket)
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasSuffix("]") && !trimmed.contains("```") {
            DebugLog.persist("vision",
                "WARNING: response appears truncated — consider increasing visionMaxTokens")
        }

        guard let jsonString = extractJSON(from: responseText) else {
            DebugLog.log("vision", "parse: no JSON array found in response")
            return ([], [])
        }

        // Decode element-by-element so one malformed element doesn't
        // discard the entire array. Skip elements without coordinates.
        guard let data = jsonString.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            DebugLog.log("vision", "parse: JSON decode failed")
            return ([], [])
        }

        let decoder = JSONDecoder()
        var visionElements = [VisionElement]()
        for obj in jsonArray {
            guard let elemData = try? JSONSerialization.data(withJSONObject: obj),
                  let ve = try? decoder.decode(VisionElement.self, from: elemData)
            else { continue }
            visionElements.append(ve)
        }

        var elements = [TapPoint]()
        var hints = [String]()
        var hasBackButton = false

        for ve in visionElements {
            let text = ve.resolvedText
            guard !text.isEmpty else { continue }

            let tapX = ve.x * scaleX
            let tapY = ve.y * scaleY

            // Normalize vision indicators into OCR-compatible elements.
            // "Entraînements chevron" → "Entraînements" + ">" (two elements).
            let normalized = normalizeIndicators(text: text, tapX: tapX, tapY: tapY)
            elements.append(contentsOf: normalized)

            // Derive navigation hints from element types
            if let type = ve.type?.lowercased() {
                if type == "back_button" || type == "back" {
                    hasBackButton = true
                }
            }
        }

        if hasBackButton {
            hints.append("has_back_button")
        }

        DebugLog.log("vision", "parse: \(elements.count) elements, \(hints.count) hints")
        return (elements, hints)
    }

    /// Extract a JSON array from text that may contain markdown fences or surrounding prose.
    ///
    /// Handles formats:
    /// - Plain JSON array: `[{"x": 1, ...}]`
    /// - Markdown fenced: `` ```json\n[...]\n``` ``
    /// - Mixed prose with embedded array
    static func extractJSON(from text: String) -> String? {
        // Try markdown fence first: ```json ... ```
        let fencePattern = "```(?:json)?\\s*\\n?(\\[.*?\\])\\s*\\n?```"
        if let regex = try? NSRegularExpression(pattern: fencePattern, options: .dotMatchesLineSeparators),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }

        // Try bare JSON array: find first [ and last ]
        if let start = text.firstIndex(of: "["),
           let end = text.lastIndex(of: "]") {
            let candidate = String(text[start...end])
            // Quick validation: try to parse it
            if let data = candidate.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] != nil {
                return candidate
            }
        }

        // Truncated array recovery: close at last complete element
        if let start = text.firstIndex(of: "[") {
            var candidate = String(text[start...])
            if let lastBrace = candidate.lastIndex(of: "}") {
                candidate = String(candidate[...lastBrace]) + "]"
                if let data = candidate.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] != nil {
                    DebugLog.log("vision", "extractJSON: recovered \(candidate.count) chars from truncated response")
                    return candidate
                }
            }
        }

        return nil
    }

    // MARK: - Vision-to-OCR Normalization

    /// Split a vision element if its text ends with a known indicator suffix.
    /// Returns 1 element (unchanged) or 2 (label + OCR indicator character).
    private static func normalizeIndicators(
        text: String, tapX: Double, tapY: Double
    ) -> [TapPoint] {
        let lower = text.lowercased()
        for indicator in indicators {
            if lower.hasSuffix(indicator.suffix) {
                let labelEnd = text.index(text.endIndex, offsetBy: -indicator.suffix.count)
                let label = String(text[text.startIndex..<labelEnd])
                    .trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else {
                    return [TapPoint(text: indicator.ocrChar, tapX: tapX, tapY: tapY, confidence: 0.85)]
                }
                return [
                    TapPoint(text: label, tapX: tapX, tapY: tapY, confidence: 0.85),
                    TapPoint(text: indicator.ocrChar, tapX: tapX + 30, tapY: tapY, confidence: 0.85),
                ]
            }
        }
        return [TapPoint(text: text, tapX: tapX, tapY: tapY, confidence: 0.85)]
    }
}
