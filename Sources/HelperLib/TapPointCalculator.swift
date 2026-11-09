// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Computes smart tap coordinates from raw OCR bounding box data.
// ABOUTME: Offsets short labels upward toward their associated icon/button.

/// Raw text element from Vision OCR, preserving full bounding box information
/// needed for smart tap-point calculation.
public struct RawTextElement: Sendable {
    /// The recognized text string.
    public let text: String
    /// X coordinate in points (horizontal center of the bounding box).
    public let tapX: Double
    /// Y coordinate of the top edge of the text bounding box (window coordinates).
    public let textTopY: Double
    /// Y coordinate of the bottom edge of the text bounding box (window coordinates).
    public let textBottomY: Double
    /// Width of the bounding box in points.
    public let bboxWidth: Double
    /// Vision confidence score (0.0–1.0).
    public let confidence: Float

    public init(
        text: String, tapX: Double, textTopY: Double,
        textBottomY: Double, bboxWidth: Double, confidence: Float
    ) {
        self.text = text
        self.tapX = tapX
        self.textTopY = textTopY
        self.textBottomY = textBottomY
        self.bboxWidth = bboxWidth
        self.confidence = confidence
    }
}

/// Where an element's text came from.
public enum TextSource: String, Sendable, Codable, Equatable {
    /// Read from the frame's pixels, by OCR or a vision model: it may be misread.
    case pixels
    /// Reported by the OS accessibility tree: exact.
    case tree
}

/// A finalized tap point with coordinates ready for use by the tap tool.
public struct TapPoint: Sendable, Codable, Equatable {
    /// The recognized text string.
    public let text: String
    /// X coordinate in points, relative to the mirroring window top-left.
    public let tapX: Double
    /// Y coordinate in points, relative to the mirroring window top-left (viewport-relative).
    public let tapY: Double
    /// Page-absolute Y coordinate, incorporating cumulative scroll offset.
    /// For single-viewport contexts this equals `tapY`. For scroll-collected elements
    /// this encodes the true vertical position on the full page.
    public let pageY: Double
    /// Vision confidence score (0.0–1.0).
    public let confidence: Float
    /// Where the text came from. In a saved file the key is written only for
    /// text that did not come from pixels, and absent means pixels.
    public let source: TextSource

    public init(text: String, tapX: Double, tapY: Double, confidence: Float, pageY: Double? = nil,
                source: TextSource = .pixels) {
        self.text = text
        self.tapX = tapX
        self.tapY = tapY
        self.pageY = pageY ?? tapY
        self.confidence = confidence
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case text, tapX, tapY, pageY, confidence, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        tapX = try container.decode(Double.self, forKey: .tapX)
        tapY = try container.decode(Double.self, forKey: .tapY)
        pageY = try container.decode(Double.self, forKey: .pageY)
        confidence = try container.decode(Float.self, forKey: .confidence)
        source = try container.decodeIfPresent(TextSource.self, forKey: .source) ?? .pixels
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(tapX, forKey: .tapX)
        try container.encode(tapY, forKey: .tapY)
        try container.encode(pageY, forKey: .pageY)
        try container.encode(confidence, forKey: .confidence)
        if source != .pixels { try container.encode(source, forKey: .source) }
    }
}

/// Converts raw OCR bounding box data into smart tap coordinates.
/// Short labels (e.g. app icon names) are offset upward toward the icon above them,
/// since Vision only detects the text label, not the icon itself.
///
/// The calculation runs as a three-stage pipeline:
/// 1. ``groupIntoRows`` — cluster sorted elements within ``rowTolerance``
/// 2. ``classifyRows`` — tag each row as icon/regular, compute gap from above
/// 3. ``applyOffsets`` — produce final ``TapPoint`` array from classified rows
public enum TapPointCalculator {
    /// Max label length for "short label" classification.
    static var maxLabelLength: Int { EnvConfig.tapMaxLabelLength }
    /// Max label width as fraction of window width for "short label".
    static var maxLabelWidthFraction: Double { EnvConfig.tapMaxLabelWidthFraction }
    /// Minimum gap above to trigger upward offset. Set high enough to avoid
    /// false positives on in-app buttons (e.g. Waze shortcut pills, ~40pt gap)
    /// while still catching home screen icon labels (gaps typically 60-150pt
    /// between rows).
    static var minGapForOffset: Double { EnvConfig.tapMinGapForOffset }
    /// Minimum short labels in a row to be classified as an icon grid row.
    /// Icon rows use the gap from the previous multi-element row, bypassing
    /// stray OCR text detected inside icons (e.g. Calendar date, Clock numbers).
    static var iconRowMinLabels: Int { EnvConfig.tapIconRowMinLabels }
    /// Fixed upward offset applied to short labels when a gap is detected.
    /// Matches the typical distance from an icon label to the icon center
    /// on iOS home screens (~30pt).
    static var iconOffset: Double { EnvConfig.tapIconOffset }
    /// Elements within this vertical distance are treated as the same row.
    /// Ensures all labels in an icon row get the same gap calculation.
    static var rowTolerance: Double { EnvConfig.tapRowTolerance }
    /// Maximum allowed `maxSpacing / minSpacing` ratio between adjacent
    /// elements before a row is rejected as an icon-grid row. Prevents
    /// horizontal in-content toolbars (variable-width buttons) from
    /// triggering the upward icon-label offset.
    static var iconRowMaxSpacingRatio: Double { EnvConfig.tapIconRowMaxSpacingRatio }

    // MARK: - Pipeline stage types

    /// A horizontal row of elements at approximately the same vertical position.
    public struct Row: Sendable {
        /// Elements in this row, sorted left-to-right by original order.
        public let elements: [RawTextElement]
        /// Maximum textBottomY across all elements in the row.
        public let bottomY: Double
    }

    /// A row annotated with classification and gap data from the row above.
    public struct ClassifiedRow: Sendable {
        /// The underlying row.
        public let row: Row
        /// Whether this row qualifies as an icon grid row (3+ short labels).
        public let isIconRow: Bool
        /// Vertical gap from the bottom of the reference row above.
        public let gap: Double
        /// Whether this icon row is in the bottom zone of the window (e.g. tab bar).
        /// When true, the upward offset is applied regardless of gap size.
        public let isInBottomZone: Bool
    }

    // MARK: - Stage 1: Group into rows

    /// Groups sorted elements into rows where all elements share approximately
    /// the same textTopY (within ``rowTolerance``).
    public static func groupIntoRows(_ sorted: [RawTextElement]) -> [Row] {
        guard !sorted.isEmpty else { return [] }
        var rows: [Row] = []
        var idx = 0

        while idx < sorted.count {
            let rowTopY = sorted[idx].textTopY
            var rowEnd = idx + 1
            while rowEnd < sorted.count
                && sorted[rowEnd].textTopY - rowTopY < rowTolerance {
                rowEnd += 1
            }

            let rowElements = Array(sorted[idx..<rowEnd])
            let bottomY = rowElements.map(\.textBottomY).max() ?? rowTopY
            rows.append(Row(elements: rowElements, bottomY: bottomY))
            idx = rowEnd
        }

        return rows
    }

    // MARK: - Stage 2: Classify rows

    /// Annotates each row with icon-row classification and gap from the row above.
    ///
    /// Icon rows measure their gap from the previous multi-element row,
    /// bypassing single-element OCR fragments inside icons (e.g. Calendar date).
    /// Icon rows in the bottom zone of the window (e.g. tab bars) are flagged
    /// so the offset can be applied regardless of gap size.
    public static func classifyRows(
        _ rows: [Row], windowWidth: Double, windowHeight: Double
    ) -> [ClassifiedRow] {
        let bottomZoneY = windowHeight * EnvConfig.tapBottomZoneFraction
        var classified: [ClassifiedRow] = []
        var previousRowBottomY: Double = 0.0
        var previousMultiRowBottomY: Double = 0.0

        for row in rows {
            let rowTopY = row.elements[0].textTopY
            let shortLabelsInRow = row.elements.filter {
                $0.text.count <= maxLabelLength
                    && $0.bboxWidth < windowWidth * maxLabelWidthFraction
            }.count
            let allShortLabels = shortLabelsInRow == row.elements.count
            let isIconRow = allShortLabels
                && shortLabelsInRow >= iconRowMinLabels
                && hasUniformSpacing(row.elements)

            let gap: Double
            if isIconRow {
                gap = rowTopY - previousMultiRowBottomY
            } else {
                gap = rowTopY - previousRowBottomY
            }

            let isInBottomZone = isIconRow && rowTopY >= bottomZoneY

            classified.append(ClassifiedRow(
                row: row, isIconRow: isIconRow, gap: gap,
                isInBottomZone: isInBottomZone
            ))

            previousRowBottomY = max(previousRowBottomY, row.bottomY)
            if row.elements.count >= 2 {
                previousMultiRowBottomY = max(previousMultiRowBottomY, row.bottomY)
            }
        }

        return classified
    }

    // MARK: - Spacing uniformity check

    /// Returns true when adjacent elements in `elements` are spaced uniformly
    /// enough to look like an icon grid (e.g. iOS home screen, tab bar).
    /// Returns false for horizontal in-content toolbars whose buttons have
    /// widely varying widths and uneven gaps (e.g. Chrome's download bar).
    ///
    /// The check compares the largest and smallest gap between adjacent
    /// element X centers; the ratio stays near 1.0 for icon grids and
    /// blows up (≥4×) for ad-hoc toolbars. Rows with fewer than 3
    /// elements never reach this check (caller has already gated on the
    /// `iconRowMinLabels` count).
    public static func hasUniformSpacing(_ elements: [RawTextElement]) -> Bool {
        let xs = elements.map(\.tapX).sorted()
        guard xs.count >= 3 else { return true }

        var spacings: [Double] = []
        for i in 1..<xs.count {
            spacings.append(xs[i] - xs[i - 1])
        }
        guard let minGap = spacings.min(),
              let maxGap = spacings.max(),
              minGap > 0 else { return true }
        return maxGap / minGap <= iconRowMaxSpacingRatio
    }

    // MARK: - Stage 3: Apply offsets

    /// Converts classified rows into final tap points by applying the upward
    /// offset to icon rows with a sufficient gap above.
    public static func applyOffsets(_ classifiedRows: [ClassifiedRow]) -> [TapPoint] {
        var results: [TapPoint] = []

        for classified in classifiedRows {
            for element in classified.row.elements {
                let tapY: Double
                let textCenterY = (element.textTopY + element.textBottomY) / 2.0
                if classified.isIconRow
                    && (classified.gap > minGapForOffset || classified.isInBottomZone) {
                    let offset = iconOffset
                    tapY = max(element.textTopY - offset, 0.0)
                } else {
                    tapY = textCenterY
                }

                results.append(TapPoint(
                    text: element.text,
                    tapX: element.tapX,
                    tapY: tapY,
                    confidence: element.confidence
                ))
            }
        }

        return results
    }

    // MARK: - Public entry point

    /// Compute tap points from raw OCR elements, applying upward offsets
    /// to short labels that have significant gaps above them (indicating
    /// an icon or button is above the text).
    ///
    /// Elements at the same vertical position (within `rowTolerance`) are
    /// processed as a batch so they all share the same gap from the row above.
    public static func computeTapPoints(
        elements: [RawTextElement], windowWidth: Double, windowHeight: Double
    ) -> [TapPoint] {
        let sorted = elements.sorted { $0.textTopY < $1.textTopY }
        let rows = groupIntoRows(sorted)
        let classified = classifyRows(rows, windowWidth: windowWidth, windowHeight: windowHeight)
        return applyOffsets(classified)
    }
}
