// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Classifies OCR elements by role (navigation, toggle, info, decoration) using text patterns and spatial proximity.
// ABOUTME: Row grouping by Y-coordinate enables chevron and toggle detection to identify navigation vs state-change elements.

import Foundation
import HelperLib

/// The role of an OCR element in the app UI, determined by text patterns and spatial context.
enum ElementRole: String, Sendable {
    /// Leads to a new screen (nearby ">" chevron, or unclassified fallback).
    case navigation
    /// Toggle row — a label paired with a nearby state indicator ("On"/"Off").
    case stateChange
    /// Matches destructive/dangerous skip patterns.
    case destructive
    /// A value or state indicator text ("3.2 GB", "On", "Off", "Connected").
    case info
    /// Chevrons (">", "<"), punctuation-only, or very short text.
    case decoration
}

/// An OCR element annotated with its classified role.
struct ClassifiedElement: Sendable {
    /// The original tap point from OCR.
    let point: TapPoint
    /// The classified role of this element.
    let role: ElementRole
    /// True when the element's row contained a chevron (">" indicator), signaling
    /// stronger confidence that tapping it will navigate to a new screen.
    let hasChevronContext: Bool

    init(point: TapPoint, role: ElementRole, hasChevronContext: Bool = false) {
        self.point = point
        self.role = role
        self.hasChevronContext = hasChevronContext
    }
}

/// Classifies OCR elements by role using text patterns and spatial proximity.
/// Pure transformation: all static methods, no stored state.
enum ElementClassifier {

    /// Y-coordinate tolerance for grouping elements into the same row.
    static let rowTolerance: Double = 15.0

    /// Chevron characters that indicate a navigation target on the same row.
    static let chevronCharacters: Set<String> = [">", "›", "\u{203A}", "\u{276F}"]

    /// State indicator words that mark a toggle row when paired with a label.
    static let stateIndicators: Set<String> = [
        "on", "off",
    ]

    /// Dismiss button characters that indicate a modal sheet close target.
    static let dismissCharacters: Set<String> = [
        "x", "X", "✕", "×", "✖", "xmark",
    ]

    /// Standalone info words that are not navigation targets.
    static let infoWords: Set<String> = [
        "on", "off", "none", "auto", "connected", "enabled", "disabled",
        "default", "never", "always", "manual",
    ]

    /// Regex matching value patterns like "3.2 GB", "128 MB", "50%", "2.1 KB".
    static let valuePattern = try! NSRegularExpression(
        pattern: #"^\d+(\.\d+)?\s*(GB|MB|KB|TB|%)$"#, options: .caseInsensitive
    )

    /// Regex matching time patterns like "15:02", "9:41", "15:011" (OCR artifacts).
    static let timePattern = try! NSRegularExpression(
        pattern: #"^\d{1,2}:\d{2}\d?$"#
    )

    /// Fraction of screen height defining the status bar zone at the top.
    /// Elements in this zone are classified as decoration (clock, battery, signal).
    static let statusBarZoneFraction: Double = 0.10

    // MARK: - Classification

    /// Classify all OCR elements using text patterns and spatial proximity.
    ///
    /// Priority order:
    /// 0. Decoration: elements in the status bar zone (top ~10% of screen)
    /// 1. Decoration: chevrons, punctuation-only
    /// 2. Info: standalone state words, value patterns, or time patterns
    /// 3. Decoration: short text under 3 chars (that isn't an info word)
    /// 4. Destructive: matches skip patterns
    /// 5. State change: label on a row WITH a state indicator
    /// 6. Navigation: label on a row WITH a chevron
    /// 7. Fallback: anything unclassified becomes navigation
    ///
    /// - Parameters:
    ///   - elements: Raw OCR tap points.
    ///   - budget: Exploration budget for destructive pattern checks.
    ///   - screenHeight: Height of the target window for status bar zone calculation.
    ///     Pass 0 to disable zone filtering.
    /// - Returns: Classified elements preserving original order.
    static func classify(
        _ elements: [TapPoint],
        budget: ExplorationBudget = .default,
        screenHeight: Double = 0
    ) -> [ClassifiedElement] {
        let rows = groupIntoRows(elements)

        // Build per-row context: which rows have chevrons, which have state indicators
        var rowHasChevron: [Int: Bool] = [:]
        var rowHasStateIndicator: [Int: Bool] = [:]

        for (rowIndex, row) in rows.enumerated() {
            rowHasChevron[rowIndex] = row.contains { isChevron($0.text) }
            rowHasStateIndicator[rowIndex] = row.contains { isStateIndicator($0.text) }
        }

        // Map each element to its row index for lookup
        var elementToRow: [String: Int] = [:]
        for (rowIndex, row) in rows.enumerated() {
            for element in row {
                let key = elementKey(element)
                elementToRow[key] = rowIndex
            }
        }

        var result = elements.map { element in
            let (role, chevronContext) = classifySingle(
                element, budget: budget,
                screenHeight: screenHeight,
                elementToRow: elementToRow,
                rowHasChevron: rowHasChevron,
                rowHasStateIndicator: rowHasStateIndicator
            )
            return ClassifiedElement(point: element, role: role, hasChevronContext: chevronContext)
        }

        // Second pass: reclassify paragraph fragments (consecutive rows of short
        // fallback-nav text that OCR split into individual lines).
        reclassifyParagraphFragments(
            &result, rows: rows, elementToRow: elementToRow,
            rowHasChevron: rowHasChevron, rowHasStateIndicator: rowHasStateIndicator
        )

        return result
    }

    /// Group elements into rows by Y-coordinate proximity.
    ///
    /// Elements within `tolerance` points of each other vertically are grouped together.
    /// Rows are sorted by ascending Y position.
    ///
    /// - Parameters:
    ///   - elements: OCR tap points to group.
    ///   - tolerance: Maximum Y-distance to consider elements on the same row.
    /// - Returns: Array of rows, each containing elements at similar Y positions.
    static func groupIntoRows(
        _ elements: [TapPoint],
        tolerance: Double = 15.0
    ) -> [[TapPoint]] {
        guard !elements.isEmpty else { return [] }

        // Sort and group by page-absolute Y so multi-viewport merged elements
        // are correctly ordered by their position on the full page.
        let sorted = elements.sorted { $0.pageY < $1.pageY }
        var rows: [[TapPoint]] = []
        var currentRow: [TapPoint] = [sorted[0]]

        for element in sorted.dropFirst() {
            if let last = currentRow.last, abs(element.pageY - last.pageY) <= tolerance {
                currentRow.append(element)
            } else {
                rows.append(currentRow)
                currentRow = [element]
            }
        }
        rows.append(currentRow)
        return rows
    }

    // MARK: - Paragraph Fragment Detection

    /// Minimum consecutive rows of qualifying text to be considered a paragraph run.
    static let paragraphRunMinRows: Int = 3

    /// Reclassify paragraph fragments: consecutive rows of short fallback-nav text
    /// without structural signals (no chevron, no toggle, no button).
    ///
    /// OCR splits paragraph text into individual lines (~30-40 chars each). Each line
    /// bypasses the >50 char threshold and the comma+conjunction check, falling through
    /// to the `navigation` fallback. This second pass detects runs of 3+ consecutive rows
    /// where every element is a multi-word fallback-nav fragment, and reclassifies them
    /// as `.info` to prevent BFS from wasting actions on paragraph text.
    ///
    /// A qualifying element must:
    /// - Be classified as `.navigation` without chevron context (fallback)
    /// - Contain spaces (multi-word — not a single-word button label)
    /// - Be on a row with no chevron and no state indicator
    static func reclassifyParagraphFragments(
        _ classified: inout [ClassifiedElement],
        rows: [[TapPoint]],
        elementToRow: [String: Int],
        rowHasChevron: [Int: Bool],
        rowHasStateIndicator: [Int: Bool]
    ) {
        // Build a set of element keys per row that qualify as paragraph fragments
        var qualifyingKeysByRow: [Int: Set<String>] = [:]
        for element in classified {
            let key = elementKey(element.point)
            guard let rowIndex = elementToRow[key] else { continue }
            guard element.role == .navigation && !element.hasChevronContext else { continue }
            guard element.point.text.contains(" ") else { continue }
            guard rowHasChevron[rowIndex] != true else { continue }
            guard rowHasStateIndicator[rowIndex] != true else { continue }

            qualifyingKeysByRow[rowIndex, default: []].insert(key)
        }

        // Find runs of consecutive row indices where every row has qualifying elements
        let sortedRowIndices = qualifyingKeysByRow.keys.sorted()
        var runs: [[Int]] = []
        var currentRun: [Int] = []

        for rowIndex in sortedRowIndices {
            if let last = currentRun.last, rowIndex == last + 1 {
                currentRun.append(rowIndex)
            } else {
                if currentRun.count >= paragraphRunMinRows {
                    runs.append(currentRun)
                }
                currentRun = [rowIndex]
            }
        }
        if currentRun.count >= paragraphRunMinRows {
            runs.append(currentRun)
        }

        guard !runs.isEmpty else { return }

        // Collect all qualifying keys in paragraph runs
        var keysToReclassify = Set<String>()
        for run in runs {
            for rowIndex in run {
                if let keys = qualifyingKeysByRow[rowIndex] {
                    keysToReclassify.formUnion(keys)
                }
            }
        }

        // Reclassify matching elements as .info
        for i in classified.indices {
            let key = elementKey(classified[i].point)
            if keysToReclassify.contains(key) {
                classified[i] = ClassifiedElement(
                    point: classified[i].point, role: .info, hasChevronContext: false
                )
            }
        }
    }

    // MARK: - Private

    /// Classify a single element given its row context.
    /// Returns a tuple of (role, hasChevronContext).
    private static func classifySingle(
        _ element: TapPoint,
        budget: ExplorationBudget,
        screenHeight: Double,
        elementToRow: [String: Int],
        rowHasChevron: [Int: Bool],
        rowHasStateIndicator: [Int: Bool]
    ) -> (ElementRole, Bool) {
        let text = element.text

        // 0. Status bar zone: elements in the top portion of the screen are
        //    clock, battery, and signal indicators — never navigation targets.
        if screenHeight > 0 && element.tapY < screenHeight * statusBarZoneFraction {
            return (.decoration, false)
        }

        // 1. Decoration: chevrons, punctuation-only
        if isChevron(text) || LandmarkPicker.isPunctuationOnly(text) {
            return (.decoration, false)
        }

        // 2. Info: standalone state/value words, or time patterns like "15:02"
        //    (checked before short-text filter because "On"/"Off" are 2 chars
        //    but are meaningful state indicators)
        if isInfoText(text) {
            return (.info, false)
        }

        // 3. Decoration: very short text that isn't an info word
        if text.count < LandmarkPicker.landmarkMinLength {
            return (.decoration, false)
        }

        // 4. Destructive: matches skip patterns
        if budget.shouldSkipElement(text: text) {
            return (.destructive, false)
        }

        // Look up this element's row
        let key = elementKey(element)
        guard let rowIndex = elementToRow[key] else {
            return (.navigation, false)
        }

        // 5. State change: label on a row with a state indicator
        if rowHasStateIndicator[rowIndex] == true && !isStateIndicator(text) {
            return (.stateChange, false)
        }

        // 6. Navigation: label on a row with a chevron
        if rowHasChevron[rowIndex] == true {
            return (.navigation, true)
        }

        // 6b. Long descriptive text (> 50 chars) without row context -> info
        if text.count > 50 {
            return (.info, false)
        }

        // 6c. Sentence-like text (comma + conjunction) -> info
        if isSentenceLike(text) {
            return (.info, false)
        }

        // 6d. Help/learn-more links -> info
        if isHelpLink(text) {
            return (.info, false)
        }

        // 7. Fallback: unclassified labels default to navigation (no chevron context)
        return (.navigation, false)
    }

    /// Check if text is a chevron character.
    private static func isChevron(_ text: String) -> Bool {
        chevronCharacters.contains(text.trimmingCharacters(in: .whitespaces))
    }

    /// Check if text is a state indicator ("On", "Off").
    private static func isStateIndicator(_ text: String) -> Bool {
        stateIndicators.contains(text.lowercased().trimmingCharacters(in: .whitespaces))
    }

    /// Check if text is an info/value string (state words, value patterns, or time patterns).
    private static func isInfoText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if infoWords.contains(trimmed.lowercased()) {
            return true
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if valuePattern.firstMatch(in: trimmed, range: range) != nil {
            return true
        }
        return timePattern.firstMatch(in: trimmed, range: range) != nil
    }

    /// Generate a unique key for an element based on text and position.
    /// Needed because the same text may appear at different positions.
    private static func elementKey(_ element: TapPoint) -> String {
        "\(element.text)@\(Int(element.tapX)),\(Int(element.tapY))"
    }

    /// Conjunctions used to detect sentence-like text (English and French).
    private static let conjunctions: Set<String> = [
        "and", "or", "but", "et", "ou", "mais",
    ]

    /// Check if text reads like a sentence (contains a comma AND a conjunction).
    private static func isSentenceLike(_ text: String) -> Bool {
        guard text.contains(",") else { return false }
        let lowered = text.lowercased()
        let words = Set(lowered.split(separator: " ").map(String.init))
        return !conjunctions.isDisjoint(with: words)
    }

    /// Patterns matching help/learn-more links that are not navigation targets.
    private static let helpLinkPatterns: [String] = [
        "learn more", "en savoir plus", "mas informacion", "weitere infos",
        "see how", "find out", "how to",
    ]

    /// Check if text is a help/learn-more link.
    private static func isHelpLink(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return helpLinkPatterns.contains { lowered.contains($0) }
    }

}
