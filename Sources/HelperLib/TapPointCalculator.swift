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
public enum TapPointCalculator {
    /// Max label length for "short label" classification.
    static let maxLabelLength = 15
    /// Max label width as fraction of window width for "short label".
    static let maxLabelWidthFraction = 0.4
    /// Minimum gap above to trigger upward offset. Set high enough to avoid
    /// false positives on in-app buttons (e.g. Waze shortcut pills, ~40pt gap)
    /// while still catching home screen icon labels (gaps typically 60-150pt
    /// between rows).
    static let minGapForOffset: Double = 50.0
    /// Minimum short labels in a row to be classified as an icon grid row.
    /// Icon rows use the gap from the previous multi-element row, bypassing
    /// stray OCR text detected inside icons (e.g. Calendar date, Clock numbers).
    static let iconRowMinLabels = 3
    /// Fixed upward offset applied to short labels when a gap is detected.
    /// Matches the typical distance from an icon label to the icon center
    /// on iOS home screens (~30pt).
    static let iconOffset: Double = 30.0
    /// Elements within this vertical distance are treated as the same row.
    /// Ensures all labels in an icon row get the same gap calculation.
    static let rowTolerance: Double = 10.0

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

        var results: [TapPoint] = []
        var previousRowBottomY: Double = 0.0
        var previousMultiRowBottomY: Double = 0.0
        var idx = 0

        while idx < sorted.count {
            // Collect all elements in the same row (textTopY within tolerance)
            let rowTopY = sorted[idx].textTopY
            var rowEnd = idx + 1
            while rowEnd < sorted.count
                && sorted[rowEnd].textTopY - rowTopY < rowTolerance {
                rowEnd += 1
            }

            // The offset is a row-level decision: only icon grid rows (3+ short
            // labels) get the upward offset. Single short labels (e.g. Settings
            // list items like "Général") use text center to avoid false offsets
            // into section separator gaps.
            let rowSize = rowEnd - idx
            let shortLabelsInRow = (idx..<rowEnd).filter { j in
                sorted[j].text.count <= maxLabelLength
                    && sorted[j].bboxWidth < windowWidth * maxLabelWidthFraction
            }.count
            let allShortLabels = shortLabelsInRow == rowSize
            let isIconRow = allShortLabels && shortLabelsInRow >= iconRowMinLabels

            // Icon rows measure gap from the previous multi-element row,
            // bypassing single-element OCR fragments inside icons.
            let gap: Double
            if isIconRow {
                gap = rowTopY - previousMultiRowBottomY
            } else {
                gap = rowTopY - previousRowBottomY
            }

            for j in idx..<rowEnd {
                let element = sorted[j]

                let tapY: Double
                let textCenterY = (element.textTopY + element.textBottomY) / 2.0
                if isIconRow && gap > minGapForOffset {
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

            // Advance previousRowBottomY to the max textBottomY in this row
            for j in idx..<rowEnd {
                previousRowBottomY = max(previousRowBottomY, sorted[j].textBottomY)
            }

            // Advance previousMultiRowBottomY only for rows with 2+ elements
            if (rowEnd - idx) >= 2 {
                for j in idx..<rowEnd {
                    previousMultiRowBottomY = max(previousMultiRowBottomY, sorted[j].textBottomY)
                }
            }

            idx = rowEnd
        }

        return results
    }
}
