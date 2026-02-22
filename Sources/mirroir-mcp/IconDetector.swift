// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Detects unlabeled icons (tab bars, toolbars) via pixel clustering with Vision saliency fallback.
// ABOUTME: Returns estimated tap coordinates for icon regions that OCR cannot see.

import CoreGraphics
import Foundation
import HelperLib
import Vision

/// Detects unlabeled icons in OCR-empty zones of the screen.
/// Uses column-projection pixel clustering on solid backgrounds, falling back
/// to Vision saliency detection for translucent/gradient backgrounds.
enum IconDetector {

    /// A detected icon region with its estimated center tap coordinates.
    struct DetectedIcon: Sendable {
        /// Window-coordinate X (center of icon).
        let tapX: Double
        /// Window-coordinate Y (center of icon).
        let tapY: Double
        /// Approximate icon dimension in points.
        let estimatedSize: Double
    }

    /// A horizontal band of the window with few or no OCR elements.
    struct EmptyZone: Sendable {
        /// Top edge in window coordinates.
        let yStart: Double
        /// Bottom edge in window coordinates.
        let yEnd: Double
    }

    // MARK: - Entry Point

    /// Detect unlabeled icons in OCR-empty zones of the screen.
    ///
    /// - Parameters:
    ///   - image: The raw screenshot as a `CGImage`.
    ///   - ocrElements: OCR-detected tap points from the current screen.
    ///   - windowSize: Size of the mirroring window in points.
    /// - Returns: Array of detected icons with estimated tap coordinates.
    static func detect(
        image: CGImage,
        ocrElements: [TapPoint],
        windowSize: CGSize
    ) -> [DetectedIcon] {
        let windowWidth = Double(windowSize.width)
        let windowHeight = Double(windowSize.height)

        let zones = findEmptyZones(
            ocrElements: ocrElements,
            windowWidth: windowWidth,
            windowHeight: windowHeight
        )

        guard !zones.isEmpty else { return [] }

        let contentRect = ContentBoundsDetector.detect(image: image)
        let displayScale = Double(image.width) / windowWidth

        var allIcons: [DetectedIcon] = []

        for zone in zones {
            var icons = IconClusterDetector.detect(
                image: image,
                zone: zone,
                contentRect: contentRect,
                displayScale: displayScale,
                windowWidth: windowWidth,
                windowHeight: windowHeight
            )

            // Always run saliency for qualifying zones and merge with clustering.
            // Clustering excels on solid-color bars with filled icons but struggles
            // with outline-style icons. Saliency catches what clustering misses.
            if (zone.yEnd - zone.yStart) >= EnvConfig.iconSaliencyMinZone {
                let saliencyIcons = detectBySaliency(
                    image: image,
                    zone: zone,
                    contentRect: contentRect,
                    displayScale: displayScale,
                    windowWidth: windowWidth,
                    windowHeight: windowHeight
                )
                icons = mergeDetections(primary: icons, secondary: saliencyIcons)
            }

            // Interpolate missing icons using even-spacing patterns.
            // Tab bars are almost always evenly spaced — if we detect 2+ icons
            // with consistent spacing, fill in the gaps.
            let singleCharOCR = ocrElements.filter {
                $0.tapY >= zone.yStart && $0.tapY <= zone.yEnd
                    && $0.text.count <= EnvConfig.iconNoiseMaxLength
            }.map { DetectedIcon(tapX: $0.tapX, tapY: $0.tapY, estimatedSize: 24) }

            let combined = mergeDetections(primary: icons, secondary: singleCharOCR)
            icons = interpolateEvenSpacing(
                detected: combined,
                windowWidth: windowWidth,
                zone: zone
            )

            allIcons.append(contentsOf: icons)
        }

        return filterNearOCR(icons: allIcons, ocrElements: ocrElements)
    }

    // MARK: - Zone Detection

    /// Identify horizontal bands with few OCR text elements.
    /// Checks the bottom 15% (tab bar) and top 12% (nav bar) of the window.
    static func findEmptyZones(
        ocrElements: [TapPoint],
        windowWidth: Double,
        windowHeight: Double
    ) -> [EmptyZone] {
        var zones: [EmptyZone] = []

        // Bottom zone: tab bar area
        let bottomStart = windowHeight * (1.0 - EnvConfig.iconBottomZoneFraction)
        let bottomZone = EmptyZone(yStart: bottomStart, yEnd: windowHeight)
        if (bottomZone.yEnd - bottomZone.yStart) >= EnvConfig.iconMinZoneHeight
            && countMeaningfulElements(ocrElements, in: bottomZone) <= EnvConfig.iconMaxZoneElements {
            zones.append(bottomZone)
        }

        // Top zone: nav bar area (skip status bar by starting at 50pt)
        let topEnd = windowHeight * EnvConfig.iconTopZoneFraction
        let topZone = EmptyZone(yStart: 50.0, yEnd: topEnd)
        if (topZone.yEnd - topZone.yStart) >= EnvConfig.iconMinZoneHeight
            && countMeaningfulElements(ocrElements, in: topZone) <= EnvConfig.iconMaxZoneElements {
            zones.append(topZone)
        }

        return zones
    }

    /// Count OCR elements in a zone, excluding single-character results that are
    /// likely icon shapes misread by OCR (e.g. magnifying glass → "Q", home → "n").
    private static func countMeaningfulElements(
        _ elements: [TapPoint], in zone: EmptyZone
    ) -> Int {
        elements.filter {
            $0.tapY >= zone.yStart && $0.tapY <= zone.yEnd
                && $0.text.count > EnvConfig.iconNoiseMaxLength
        }.count
    }

    // MARK: - Saliency Fallback

    /// Detect icons using Vision saliency when pixel clustering fails.
    /// Used for translucent or gradient backgrounds where simple thresholding misses icons.
    static func detectBySaliency(
        image: CGImage,
        zone: EmptyZone,
        contentRect: CGRect,
        displayScale: Double,
        windowWidth: Double,
        windowHeight: Double
    ) -> [DetectedIcon] {
        let contentOriginY = Double(contentRect.minY) / displayScale
        let contentHeight = Double(contentRect.height) / displayScale
        let yScale = windowHeight / max(contentHeight, 1.0)
        let contentOriginX = Double(contentRect.minX) / displayScale
        let contentWidth = Double(contentRect.width) / displayScale
        let xScale = windowWidth / max(contentWidth, 1.0)

        // Crop image to zone pixel region
        let pixelYStart = Int(((zone.yStart / yScale) + contentOriginY) * displayScale)
        let pixelYEnd = Int(((zone.yEnd / yScale) + contentOriginY) * displayScale)
        let cropY = max(0, pixelYStart)
        let cropHeight = min(image.height, pixelYEnd) - cropY

        guard cropHeight > 0 else { return [] }

        let cropRect = CGRect(x: 0, y: cropY, width: image.width, height: cropHeight)
        guard let cropped = image.cropping(to: cropRect) else { return [] }

        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observation = request.results?.first else { return [] }
        guard let salientObjects = observation.salientObjects else { return [] }

        var icons: [DetectedIcon] = []
        for obj in salientObjects {
            let bbox = obj.boundingBox
            let sizeInPts = Double(bbox.width) * Double(image.width) / displayScale

            // Skip objects too large to be icons
            guard sizeInPts <= EnvConfig.iconMaxSaliencySize else { continue }

            // Convert normalized bbox center to window coordinates
            // Vision normalized coords: origin bottom-left
            let pixelCenterX = Double(bbox.midX) * Double(image.width)
            let pixelCenterY = Double(1.0 - bbox.midY) * Double(cropHeight) + Double(cropY)

            let windowX = ((pixelCenterX / displayScale) - contentOriginX) * xScale
            let windowY = ((pixelCenterY / displayScale) - contentOriginY) * yScale

            if windowX >= 0 && windowX <= windowWidth
                && windowY >= 0 && windowY <= windowHeight {
                icons.append(DetectedIcon(
                    tapX: windowX, tapY: windowY, estimatedSize: sizeInPts
                ))
            }
        }

        return icons
    }

    // MARK: - Spacing Interpolation

    /// Infer missing icon positions from even spacing of detected icons.
    /// Tab bars use uniform spacing. When 2+ icons are detected with consistent gaps,
    /// extrapolate to fill missing positions left and right within the window bounds.
    static func interpolateEvenSpacing(
        detected: [DetectedIcon],
        windowWidth: Double,
        zone: EmptyZone
    ) -> [DetectedIcon] {
        guard detected.count >= EnvConfig.iconMinForInterpolation else { return detected }

        let sorted = detected.sorted { $0.tapX < $1.tapX }

        // Compute pairwise gaps between consecutive icons
        var gaps: [Double] = []
        for i in 1..<sorted.count {
            gaps.append(sorted[i].tapX - sorted[i - 1].tapX)
        }

        guard !gaps.isEmpty else { return detected }

        // Use median gap as the estimated spacing
        let sortedGaps = gaps.sorted()
        let medianGap = sortedGaps[sortedGaps.count / 2]

        // Verify spacing is roughly even: all gaps within tolerance of the median
        let maxDeviation = medianGap * EnvConfig.iconSpacingTolerance
        let allConsistent = gaps.allSatisfy { abs($0 - medianGap) <= maxDeviation }

        guard allConsistent && medianGap > 10.0 else { return detected }

        // Average Y position of detected icons
        let avgY = sorted.map(\.tapY).reduce(0, +) / Double(sorted.count)
        let avgSize = sorted.map(\.estimatedSize).reduce(0, +) / Double(sorted.count)

        var result = Array(sorted)

        // Extrapolate left from the leftmost icon
        var x = sorted.first!.tapX - medianGap
        while x > medianGap * 0.3 {
            result.append(DetectedIcon(tapX: x, tapY: avgY, estimatedSize: avgSize))
            x -= medianGap
        }

        // Extrapolate right from the rightmost icon
        x = sorted.last!.tapX + medianGap
        while x < windowWidth - medianGap * 0.3 {
            result.append(DetectedIcon(tapX: x, tapY: avgY, estimatedSize: avgSize))
            x += medianGap
        }

        return result
    }

    // MARK: - Merging & Filtering

    /// Merge two detection result sets, keeping primary detections and adding
    /// secondary detections that aren't near any primary detection.
    static func mergeDetections(
        primary: [DetectedIcon], secondary: [DetectedIcon]
    ) -> [DetectedIcon] {
        var merged = primary
        for candidate in secondary {
            let isDuplicate = merged.contains { existing in
                let dx = candidate.tapX - existing.tapX
                let dy = candidate.tapY - existing.tapY
                return (dx * dx + dy * dy).squareRoot() < EnvConfig.iconDeduplicationRadius
            }
            if !isDuplicate {
                merged.append(candidate)
            }
        }
        return merged
    }

    /// Remove detected icons that are within proximity of existing OCR TapPoints.
    static func filterNearOCR(
        icons: [DetectedIcon],
        ocrElements: [TapPoint]
    ) -> [DetectedIcon] {
        icons.filter { icon in
            !ocrElements.contains { el in
                let dx = icon.tapX - el.tapX
                let dy = icon.tapY - el.tapY
                return (dx * dx + dy * dy).squareRoot() < EnvConfig.iconOcrProximityFilter
            }
        }
    }

}
