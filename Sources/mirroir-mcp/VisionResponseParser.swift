// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Parses AI vision model responses into TapPoint arrays for screen description.
// ABOUTME: Handles JSON extraction from markdown-fenced responses and coordinate scaling.

import Foundation
import HelperLib

/// Parses AI vision model responses into structured screen elements.
enum VisionResponseParser {

    /// A single element detected by the vision model.
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
        guard let jsonString = extractJSON(from: responseText) else {
            DebugLog.log("vision", "parse: no JSON array found in response")
            return ([], [])
        }

        guard let data = jsonString.data(using: .utf8),
              let visionElements = try? JSONDecoder().decode([VisionElement].self, from: data)
        else {
            DebugLog.log("vision", "parse: JSON decode failed")
            return ([], [])
        }

        var elements = [TapPoint]()
        var hints = [String]()
        var hasBackButton = false

        for ve in visionElements {
            let text = ve.resolvedText
            guard !text.isEmpty else { continue }

            let tapX = ve.x * scaleX
            let tapY = ve.y * scaleY

            elements.append(TapPoint(
                text: text,
                tapX: tapX,
                tapY: tapY,
                confidence: 0.85
            ))

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

        return nil
    }
}
