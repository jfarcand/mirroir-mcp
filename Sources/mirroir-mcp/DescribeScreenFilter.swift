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

    /// The mark on an element whose text the accessibility tree reported.
    static let treeMark = "[tree]"

    /// One line per element: its quoted text, then its tap point unless
    /// `textOnly`, then `treeMark` when the text is exact. A pixel-read
    /// element carries no mark, so a screen with no tree text reads as before.
    static func lines(for elements: [TapPoint], textOnly: Bool) -> [String] {
        elements.map { element in
            let line = textOnly
                ? "- \"\(element.text)\""
                : "- \"\(element.text)\" at (\(Int(element.tapX)), \(Int(element.tapY)))"
            return element.source == .tree ? "\(line) \(treeMark)" : line
        }
    }

    /// The first line of the element list. It explains the tree mark only
    /// when an element carries it. `coordinates` says which points are listed.
    static func header(coordinates: String, elements: [TapPoint]) -> String {
        guard elements.contains(where: { $0.source == .tree }) else {
            return "Screen elements (\(coordinates)):"
        }
        return "Screen elements (\(coordinates); \(treeMark) = exact text from the macOS "
            + "accessibility tree, unmarked = read from pixels, may misread):"
    }

    /// The `_meta` fields that count elements by source, when any is exact.
    static func sourceCounts(_ elements: [TapPoint], truncated: Bool) -> String {
        let tree = elements.filter { $0.source == .tree }.count
        guard tree > 0 || truncated else { return "" }
        return " tree_count=\(tree) pixel_count=\(elements.count - tree)"
            + (truncated ? " tree_truncated=true" : "")
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
