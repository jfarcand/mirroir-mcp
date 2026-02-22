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

/// A finalized tap point with coordinates ready for use by the tap tool.
public struct TapPoint: Sendable {
    /// The recognized text string.
    public let text: String
    /// X coordinate in points, relative to the mirroring window top-left.
    public let tapX: Double
    /// Y coordinate in points, relative to the mirroring window top-left.
    public let tapY: Double
    /// Vision confidence score (0.0–1.0).
    public let confidence: Float
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
    public static func classifyRows(
        _ rows: [Row], windowWidth: Double
    ) -> [ClassifiedRow] {
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
            let isIconRow = allShortLabels && shortLabelsInRow >= iconRowMinLabels

            let gap: Double
            if isIconRow {
                gap = rowTopY - previousMultiRowBottomY
            } else {
                gap = rowTopY - previousRowBottomY
            }

            classified.append(ClassifiedRow(row: row, isIconRow: isIconRow, gap: gap))

            previousRowBottomY = max(previousRowBottomY, row.bottomY)
            if row.elements.count >= 2 {
                previousMultiRowBottomY = max(previousMultiRowBottomY, row.bottomY)
            }
        }

        return classified
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
                if classified.isIconRow && classified.gap > minGapForOffset {
                    tapY = max(element.textTopY - iconOffset, 0.0)
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
        elements: [RawTextElement], windowWidth: Double
    ) -> [TapPoint] {
        let sorted = elements.sorted { $0.textTopY < $1.textTopY }
        let rows = groupIntoRows(sorted)
        let classified = classifyRows(rows, windowWidth: windowWidth)
        return applyOffsets(classified)
    }
}
