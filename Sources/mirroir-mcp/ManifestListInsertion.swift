// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Reads and inserts items of one YAML list in a manifest, leaving every other byte as it was.
// ABOUTME: Pure line-level transformation; returns nil when the list cannot be located unambiguously.

import Foundation

/// Reads the entries of a YAML list named by a key path — SAMPLE.md's
/// `session.scenarios.must_pass`, mirroir.yaml's `plan.must_pass` — and adds
/// entries to a block-style one without re-serializing the document (pure
/// transformation pattern).
///
/// The manifests the emitter owns are later edited by people and by the web
/// leg (`boot` commands, ports, `nice_to_pass`, comments). Rebuilding them from
/// a template would lose those edits, so the only change made is the inserted
/// lines. Anything this scanner cannot read with certainty — a key path
/// present twice or not at all, a flow-style, anchored or empty list, tab
/// indentation, CRLF line endings — makes `insert` return `nil`, and the
/// caller reports the lines to paste rather than guess.
enum ManifestListInsertion {

    /// Insert `items` at the end of the list `keyPath` names in `document`.
    ///
    /// - Parameters:
    ///   - document: the whole file.
    ///   - lines: the half-open range of line indices to search (the fenced
    ///     yaml block of a SAMPLE.md, or every line of a YAML file).
    ///   - keyPath: the nested mapping keys leading to the list, outermost first.
    ///   - items: each item's lines, the first starting with `- `, the rest
    ///     indented relative to that dash. They are re-indented to the list's own.
    /// - Returns: the document with the items inserted after the list's last
    ///   item, or `nil` when the list cannot be located unambiguously.
    static func insert(
        into document: String, lines range: Range<Int>, keyPath: [String], items: [[String]]
    ) -> String? {
        var lines = document.components(separatedBy: "\n")
        guard !document.contains("\r"),
              let (keyLine, block) = locate(keyPath, in: range, lines: lines),
              valueAfterColon(lines[keyLine]).isEmpty,
              let (itemIndent, extents) = listItems(block: block, lines: lines),
              let last = extents.last else { return nil }

        let pad = String(repeating: " ", count: itemIndent)
        let inserted = items.flatMap { item in item.map { pad + $0 } }
        lines.insert(contentsOf: inserted, at: last.upperBound)
        return lines.joined(separator: "\n")
    }

    /// The scalar items of the list `keyPath` names in `document`, unquoted
    /// and without trailing comments — what a YAML reader yields for a list
    /// of strings, block-style or flow-style. Commented-out items are not items.
    ///
    /// - Returns: the items (empty for `key:` with none, or `key: []`), or
    ///   `nil` when the key path is absent or repeated, or its value is not a list.
    static func scalarItems(in document: String, lines range: Range<Int>, keyPath: [String]) -> [String]? {
        readItems(in: document, lines: range, keyPath: keyPath)?.compactMap { item in
            guard let first = item.first else { return nil }
            let value = plainScalar(String(first.dropFirst(2)))
            return value.isEmpty ? nil : value
        }
    }

    /// The `key:` value of every mapping item of the list `keyPath` names in
    /// `document` — the `name` of each `plan.must_pass` entry. Items without
    /// the key contribute nothing.
    ///
    /// - Returns: the values, or `nil` when the list cannot be read.
    static func mappingValues(
        _ key: String, in document: String, lines range: Range<Int>, keyPath: [String]
    ) -> [String]? {
        readItems(in: document, lines: range, keyPath: keyPath)?.compactMap { item in
            let candidates = item.enumerated().compactMap { offset, line -> String? in
                if offset == 0 { return String(line.dropFirst(2)) }
                return indent(line) == 2 ? String(line.dropFirst(2)) : nil
            }
            guard let entry = candidates.first(where: { $0 == "\(key):" || $0.hasPrefix("\(key): ") })
            else { return nil }
            return plainScalar(String(entry.dropFirst(key.count + 1)))
        }
    }

    /// The line range of the first fenced `yaml` block of a SAMPLE.md — the
    /// only part `mirroir-run`'s SAMPLE.md loader reads — or `nil` if none is closed.
    static func fencedYamlBlock(in document: String) -> Range<Int>? {
        let lines = unixLines(document)
        guard let open = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "```yaml"
        }) else { return nil }
        guard let close = lines[(open + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }) else { return nil }
        return (open + 1)..<close
    }

    /// Every line of `document`, as a range for `insert`.
    static func wholeDocument(_ document: String) -> Range<Int> {
        0..<document.components(separatedBy: "\n").count
    }

    // MARK: - Private

    /// The lines of `document`, a CRLF line ending read as LF. Reading
    /// tolerates CRLF; `insert` refuses it rather than mix line endings.
    private static func unixLines(_ document: String) -> [String] {
        document.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// The line holding the last key of `keyPath` and the lines nested under
    /// it, or `nil` when a key is absent or repeated, `keyPath` is empty, or
    /// `range` is indented with tabs.
    private static func locate(
        _ keyPath: [String], in range: Range<Int>, lines: [String]
    ) -> (Int, Range<Int>)? {
        guard !keyPath.isEmpty, range.lowerBound >= 0, range.upperBound <= lines.count,
              !lines[range].contains(where: { $0.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") })
        else { return nil }
        var block = range
        var keyLine = -1
        for key in keyPath {
            guard let found = uniqueKey(key, in: block, lines: lines) else { return nil }
            keyLine = found
            block = childBlock(of: found, within: block, lines: lines)
        }
        return (keyLine, block)
    }

    /// Each item of the list `keyPath` names, as its lines re-indented so the
    /// dash starts the first. A flow-style list's entries come back as one
    /// `- entry` line each; `nil` when the value is neither kind of list.
    private static func readItems(in document: String, lines range: Range<Int>, keyPath: [String]) -> [[String]]? {
        let lines = unixLines(document)
        guard let (keyLine, block) = locate(keyPath, in: range, lines: lines) else { return nil }
        let value = valueAfterColon(lines[keyLine])
        if value.hasPrefix("["), value.hasSuffix("]") {
            return value.dropFirst().dropLast().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { ["- " + $0] }
        }
        guard value.isEmpty else { return nil }
        guard block.contains(where: { isContent(lines[$0]) }) else { return [] }
        guard let (itemIndent, extents) = listItems(block: block, lines: lines) else { return nil }
        return extents.map { extent in
            lines[extent].map { String($0.dropFirst(min(itemIndent, indent($0)))) }
        }
    }

    /// A scalar as YAML reads it: quotes removed, or, unquoted, a trailing
    /// ` #` comment removed.
    private static func plainScalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            let rest = value.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { return value }
            return String(rest[..<end])
        }
        let uncommented = value.range(of: " #").map { String(value[..<$0.lowerBound]) } ?? value
        return uncommented.trimmingCharacters(in: .whitespaces)
    }

    /// Leading spaces of `line`.
    private static func indent(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// A line that carries content: neither blank nor a whole-line comment.
    private static func isContent(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("#")
    }

    /// The text after `key:` on a mapping line, with a trailing comment removed.
    private static func valueAfterColon(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        var value = String(line[line.index(after: colon)...])
        if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
        if value.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return "" }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// The single line in `block` that holds `key:` at the block's own
    /// indentation (its first content line's), or `nil` if absent or repeated.
    private static func uniqueKey(_ key: String, in block: Range<Int>, lines: [String]) -> Int? {
        guard let first = block.first(where: { isContent(lines[$0]) }) else { return nil }
        let level = indent(lines[first])
        let matches = block.filter { index in
            let line = lines[index]
            guard isContent(line), indent(line) == level else { return false }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "\(key):" || trimmed.hasPrefix("\(key): ") || trimmed.hasPrefix("\(key):#")
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The lines nested under the key on `keyLine`: every line up to the next
    /// content line indented no deeper than the key — except, for a list
    /// written at the key's own indentation, its `- ` items.
    private static func childBlock(of keyLine: Int, within block: Range<Int>, lines: [String]) -> Range<Int> {
        let level = indent(lines[keyLine])
        var end = keyLine + 1
        while end < block.upperBound {
            let line = lines[end]
            if isContent(line) {
                let deeper = indent(line) > level
                let sameLevelItem = indent(line) == level
                    && line.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
                if !deeper && !sameLevelItem { break }
            }
            end += 1
        }
        return (keyLine + 1)..<end
    }

    /// Whether `line` is a `- ` list item at exactly `level` spaces.
    private static func isItem(_ line: String, at level: Int) -> Bool {
        indent(line) == level && line.dropFirst(level).hasPrefix("- ")
    }

    /// The indentation of a list's items and the line range of each item, or
    /// `nil` when `block` holds no item or holds anything other than items.
    ///
    /// An item runs from its `- ` line through the last non-blank line
    /// indented deeper than its dash — `#` lines included, since inside a
    /// `|` or `>` block scalar they are content, not comments. A comment no
    /// deeper than the dash belongs to no item.
    private static func listItems(block: Range<Int>, lines: [String]) -> (Int, [Range<Int>])? {
        guard let first = block.first(where: { isContent(lines[$0]) }) else { return nil }
        let itemIndent = indent(lines[first])
        guard isItem(lines[first], at: itemIndent) else { return nil }
        var extents: [Range<Int>] = []
        for index in block {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if isItem(line, at: itemIndent) {
                extents.append(index..<(index + 1))
            } else if indent(line) > itemIndent, let open = extents.last {
                extents[extents.count - 1] = open.lowerBound..<(index + 1)
            } else if !trimmed.hasPrefix("#") {
                return nil
            }
        }
        return (itemIndent, extents)
    }
}
