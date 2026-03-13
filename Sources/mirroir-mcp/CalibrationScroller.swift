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
        /// Total cumulative scroll offset in points (sum of all viewport offsets).
        let totalScrollOffset: Double
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
        guard let firstResult = describer.describe() else {
            return nil
        }

        var lastScreenshot = firstResult.screenshotBase64
        var scrollCount = 0
        var previousElements = firstResult.elements
        var previousTexts = Set(firstResult.elements.map(\.text))
        var cumulativeOffset: Double = 0.0

        guard let windowInfo = bridge.getWindowInfo() else {
            return ScrollResult(
                elements: firstResult.elements,
                scrollCount: 0,
                screenshotBase64: lastScreenshot,
                totalScrollOffset: 0.0
            )
        }

        let windowHeight = Double(windowInfo.size.height)
        let centerX = Double(windowInfo.size.width) / 2.0
        let scrollFromY = windowHeight * EnvConfig.scrollSwipeFromYFraction
        let scrollToY = windowHeight * EnvConfig.scrollSwipeToYFraction
        let dedupStrategy = ScrollDedupStrategy(rawValue: EnvConfig.scrollDedupStrategy) ?? .exact

        // Start with first viewport elements (page-absolute Y = viewport Y for first frame)
        var allElements = firstResult.elements

        // Cache the last successfully measured offset so subsequent viewports that
        // fail both anchor and content matching can reuse it instead of the raw
        // swipe estimate. iOS scroll physics are consistent for identical gestures,
        // so a previously measured offset is a much better approximation than the
        // swipe pixel distance (which doesn't account for scroll wheel → iOS mapping).
        var lastMeasuredOffset: Double?

        for _ in 0..<maxScrolls {
            // Swipe up (scroll content down) using configurable Y positions.
            // The midpoint must land in the upper content area of the window
            // for iPhone Mirroring to accept scroll wheel events.
            let fromX = centerX
            let fromY = scrollFromY
            let toX = centerX
            let toY = scrollToY

            if input.swipe(fromX: fromX, fromY: fromY,
                           toX: toX, toY: toY,
                           durationMs: EnvConfig.defaultSwipeDurationMs) != nil {
                break
            }

            usleep(EnvConfig.toolSettlingDelayUs)
            scrollCount += 1

            guard let result = describer.describe() else {
                break
            }

            lastScreenshot = result.screenshotBase64

            // Check scroll exhaustion: if no new texts appeared, stop
            let currentTexts = Set(result.elements.map(\.text))
            let newTexts = currentTexts.subtracting(previousTexts)
            if newTexts.isEmpty {
                break
            }

            // Compute scroll offset using content element matching.
            //
            // Anchor-based offset (fixed nav/tab bar elements) is NOT used here because
            // it measures header collapse distance, not content scroll distance. On apps
            // with collapsing headers (e.g. Santé), anchor offset can be 31pt when the
            // actual content scroll is 337pt — a 10x underestimate that breaks dedup.
            //
            // Cascade: content match → cached content offset → swipe distance estimate.
            let viewportOffset: Double
            let contentResult = ScrollAnchorDetector.computeContentOffset(
                previous: previousElements, current: result.elements,
                windowHeight: windowHeight
            )
            let swipeEstimate = scrollFromY - scrollToY
            let minOffset = EnvConfig.scrollMinOffsetThreshold

            if let content = contentResult, content.scrollOffset > minOffset {
                viewportOffset = content.scrollOffset
                lastMeasuredOffset = content.scrollOffset
                DebugLog.persist("ScrollOffset", "viewport \(scrollCount): content=\(Int(content.scrollOffset)) matches=\(content.anchorCount)")
            } else if let cached = lastMeasuredOffset {
                viewportOffset = cached
                DebugLog.persist("ScrollOffset", "viewport \(scrollCount): cached=\(Int(cached)) content=\(contentResult.map { Int($0.scrollOffset) } ?? -1)")
            } else {
                viewportOffset = swipeEstimate
                DebugLog.persist("ScrollOffset", "viewport \(scrollCount): fallback=\(Int(swipeEstimate)) content=\(contentResult.map { Int($0.scrollOffset) } ?? -1)")
            }

            cumulativeOffset += viewportOffset

            // Filter stationary elements (status bar, tab bar) from non-first viewports.
            // Viewport 0 already captured all zones; subsequent viewports only contribute
            // content-zone elements. Stationary elements get wrong pageY (shifted by
            // cumulativeOffset) and would survive dedup, creating duplicates.
            let contentTop = windowHeight * ComponentDetector.navBarZoneFraction
            let contentBottom = windowHeight * (1 - ComponentDetector.tabBarZoneFraction)
            let contentElements = result.elements.filter { el in
                el.tapY > contentTop && el.tapY < contentBottom
            }

            allElements = OverlapDeduplicator.merge(
                accumulated: allElements, newViewport: contentElements,
                cumulativeOffset: cumulativeOffset,
                viewportOffset: viewportOffset,
                windowHeight: windowHeight,
                strategy: dedupStrategy
            )

            previousElements = result.elements
            previousTexts.formUnion(currentTexts)
        }

        // Two-pass dedup:
        // 1. Strategy-based dedup (proximity/levenshtein) catches near-misses
        // 2. Exact-text dedup catches duplicates that survived due to pageY inaccuracy
        //    (e.g. same text at different estimated page positions from fallback offsets)
        let beforeCount = allElements.count
        let strategyDeduped = ScrollDeduplicator.deduplicate(allElements, strategy: dedupStrategy)
        let deduped = ScrollDeduplicator.deduplicateExact(strategyDeduped)
        DebugLog.persist("ScrollDedup", "strategy=\(dedupStrategy.rawValue) before=\(beforeCount) after_strategy=\(strategyDeduped.count) after_exact=\(deduped.count) totalOffset=\(Int(cumulativeOffset))")

        return ScrollResult(
            elements: deduped,
            scrollCount: scrollCount,
            screenshotBase64: lastScreenshot,
            totalScrollOffset: cumulativeOffset
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
