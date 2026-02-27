// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Scrolls through a full page collecting OCR elements for calibration.
// ABOUTME: Deduplicates elements by text to produce a complete element list.

import Foundation
import HelperLib

/// Collects OCR elements across multiple viewports by scrolling.
/// Pure transformation for deduplication; stateful scroll loop for collection.
enum CalibrationScroller {

    /// Result of a full-page scroll collection.
    struct ScrollResult {
        /// All unique elements found across all viewports.
        let elements: [TapPoint]
        /// Number of scroll operations performed.
        let scrollCount: Int
        /// Base64-encoded screenshot of the final viewport.
        let screenshotBase64: String
    }

    /// Scroll through a full page collecting OCR elements from each viewport.
    ///
    /// Swipes up, OCRs each viewport, deduplicates elements by text content,
    /// and detects scroll exhaustion when content stops changing.
    ///
    /// - Parameters:
    ///   - describer: Screen describer for OCR.
    ///   - input: Input provider for swipe gestures.
    ///   - bridge: Window bridge for getting window dimensions.
    ///   - maxScrolls: Maximum number of scroll attempts.
    /// - Returns: Aggregated scroll result, or nil if initial OCR fails.
    static func collectFullPage(
        describer: any ScreenDescribing,
        input: any InputProviding,
        bridge: any WindowBridging,
        maxScrolls: Int = EnvConfig.defaultScrollMaxAttempts
    ) -> ScrollResult? {
        // Start with the current viewport
        guard let firstResult = describer.describe(skipOCR: false) else {
            return nil
        }

        var allElements = firstResult.elements
        var previousTexts = Set(firstResult.elements.map { $0.text })
        var lastScreenshot = firstResult.screenshotBase64
        var scrollCount = 0

        guard let windowInfo = bridge.getWindowInfo() else {
            return ScrollResult(
                elements: allElements,
                scrollCount: 0,
                screenshotBase64: lastScreenshot
            )
        }

        let centerX = Double(windowInfo.size.width) / 2.0
        let centerY = Double(windowInfo.size.height) / 2.0
        let swipeDistance = Double(windowInfo.size.height) * EnvConfig.swipeDistanceFraction

        for _ in 0..<maxScrolls {
            // Swipe up (scroll content down)
            let fromX = centerX
            let fromY = centerY + swipeDistance / 2
            let toX = centerX
            let toY = centerY - swipeDistance / 2

            if input.swipe(fromX: fromX, fromY: fromY,
                           toX: toX, toY: toY,
                           durationMs: EnvConfig.defaultSwipeDurationMs) != nil {
                break
            }

            usleep(EnvConfig.toolSettlingDelayUs)
            scrollCount += 1

            guard let result = describer.describe(skipOCR: false) else {
                break
            }

            lastScreenshot = result.screenshotBase64

            // Check scroll exhaustion: if no new texts appeared, stop
            let currentTexts = Set(result.elements.map { $0.text })
            let newTexts = currentTexts.subtracting(previousTexts)
            if newTexts.isEmpty {
                break
            }

            // Add only elements with new text content (dedup by text)
            for element in result.elements {
                if !previousTexts.contains(element.text) {
                    allElements.append(element)
                }
            }
            previousTexts.formUnion(currentTexts)
        }

        // Apply configurable dedup strategy to the final collected set
        let strategy = ScrollDedupStrategy(rawValue: EnvConfig.scrollDedupStrategy) ?? .exact
        let beforeCount = allElements.count
        let deduped = ScrollDeduplicator.deduplicate(allElements, strategy: strategy)
        DebugLog.persist("ScrollDedup", "strategy=\(strategy.rawValue) before=\(beforeCount) after=\(deduped.count) removed=\(beforeCount - deduped.count)")

        return ScrollResult(
            elements: deduped,
            scrollCount: scrollCount,
            screenshotBase64: lastScreenshot
        )
    }

    /// Deduplicate elements by text content, keeping the element with the latest coordinates.
    /// Useful for merging elements from multiple viewports where the same text appears
    /// at different Y positions due to scrolling.
    static func deduplicateByText(_ elements: [TapPoint]) -> [TapPoint] {
        var seen: [String: TapPoint] = [:]
        for element in elements {
            seen[element.text] = element
        }
        return Array(seen.values).sorted { $0.tapY < $1.tapY }
    }
}
