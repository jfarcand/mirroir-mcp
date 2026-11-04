// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Narrows describe_screen's element list to what the agent asked for: text matching a query, with or without coordinates.
// ABOUTME: Pure transformation over OCR elements; the tool handler owns capture and the rest of the reply.

import Foundation
import HelperLib

/// The part of a describe_screen reply that lists elements. An agent that
/// only needs one value ("the price", "the temperature") passes `query` and
/// reads a line or two instead of the whole screen; `textOnly` drops the
/// coordinates when it only reads.
enum DescribeScreenFilter {

    /// The elements whose text contains `query`, ignoring case and accents, in
    /// reading order. Every element when `query` is nil or blank.
    static func matching(_ query: String?, in elements: [TapPoint]) -> [TapPoint] {
        let sorted = elements.sorted { $0.tapY < $1.tapY }
        guard let needle = query.map(fold), !needle.isEmpty else { return sorted }
        return sorted.filter { fold($0.text).contains(needle) }
    }

    /// One line per element: its quoted text, then its tap point unless `textOnly`.
    static func lines(for elements: [TapPoint], textOnly: Bool) -> [String] {
        elements.map { element in
            textOnly
                ? "- \"\(element.text)\""
                : "- \"\(element.text)\" at (\(Int(element.tapX)), \(Int(element.tapY)))"
        }
    }

    /// The line saying a query matched nothing, naming how much the screen held,
    /// so an empty answer is never mistaken for an empty screen.
    static func noMatchLine(query: String, onScreen count: Int) -> String {
        "(no element matches \"\(query)\"; \(count) element(s) on screen. "
            + "Describe again without query to see them.)"
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
